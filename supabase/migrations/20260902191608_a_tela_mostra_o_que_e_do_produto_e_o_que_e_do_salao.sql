-- A tela passa a mostrar de onde veio cada linha, e o que o produto ainda tem
-- para oferecer.
--
-- Sem isso a separação da etapa 4 existiria só no banco: o dono continuaria
-- olhando uma lista onde "Castanho 3 a 5, que o sistema chutou" e "Castanho 3
-- a 5, que eu confirmei" são visualmente a mesma linha.
--
-- As regras da profissão vão junto, e vão SÓ PARA LEITURA. Elas não têm
-- tenant_id: se a tela deixasse o dono editar, ele estaria reescrevendo o que
-- vale para todos os salões do produto. Ele pode discordar, e discordância de
-- regra é conversa com o produto, não campo de formulário.

create or replace function public.site_load_knowledge(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return jsonb_build_object(
    'dimensions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', d.id,
               'name', d.name,
               'whatToLookAt', d.what_to_look_at,
               'origin', d.origin,
               'productCode', d.product_code,
               'options', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', o.id,
                          'label', o.label,
                          'description', o.description,
                          'origin', o.origin,
                          'productCode', o.product_code,
                          'photos', coalesce((
                            select jsonb_agg(jsonb_build_object(
                                     'id', f.id,
                                     'storagePath', f.storage_path,
                                     'caption', f.caption
                                   ) order by f.position, f.created_at)
                              from app.knowledge_reference_photos f
                             where f.option_id = o.id
                          ), '[]'::jsonb)
                        ) order by o.position, o.created_at)
                   from app.knowledge_options o
                  where o.dimension_id = d.id and o.status = 'ACTIVE'
               ), '[]'::jsonb)
             ) order by d.position, d.created_at)
        from app.knowledge_dimensions d
       where d.tenant_id = target_tenant_id and d.status = 'ACTIVE'
    ), '[]'::jsonb),

    -- O que o produto tem e este salão ainda não pegou. Fica como oferta, não
    -- como linha: quem decide o que este salão observa é o dono.
    'suggestions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', pd.code,
               'name', pd.name,
               'whatToLookAt', pd.what_to_look_at,
               'options', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'code', po.code, 'label', po.label, 'description', po.description
                        ) order by po.position)
                   from app.product_knowledge_options po
                  where po.dimension_code = pd.code
               ), '[]'::jsonb)
             ) order by pd.position)
        from app.product_knowledge_dimensions pd
       where not exists (
         select 1 from app.knowledge_dimensions d
          where d.tenant_id = target_tenant_id
            and (d.product_code = pd.code or lower(d.name) = lower(pd.name))
       )
    ), '[]'::jsonb),

    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', r.code, 'subject', r.subject,
               'title', r.title, 'statement', r.statement
             ) order by r.position)
        from app.product_rules r where r.status = 'ACTIVE'
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_load_knowledge(text, text, uuid) to service_role;

-- Gravar continua substituindo o vocabulário inteiro. O que muda: o payload
-- pode dizer que uma dimensão nova veio do catálogo do produto, e aí ela nasce
-- carimbada como PRODUTO em vez de SALAO. Sem isso, aceitar uma sugestão em um
-- clique viraria "o dono escreveu isto", e o onboarding pararia de perguntar
-- sobre algo que ninguém respondeu.
--
-- Em linha que já existe o `origin` NÃO vem do payload: quem decide é o
-- gatilho, comparando o que mudou. Tela não carimba a si mesma.
create or replace function public.site_save_knowledge(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  payload                jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_dim        jsonb;
  v_opt        jsonb;
  v_photo      jsonb;
  v_dim_id     uuid;
  v_opt_id     uuid;
  v_photo_id   uuid;
  v_dim_ids    uuid[] := '{}';
  v_opt_ids    uuid[] := '{}';
  v_photo_ids  uuid[] := '{}';
  v_orfaos     text[] := '{}';
  v_pos_d      integer := 0;
  v_pos_o      integer;
  v_pos_f      integer;
  v_dim_code   text;
  v_opt_code   text;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  if jsonb_typeof(coalesce(payload->'dimensions', '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'INVALID_KNOWLEDGE_PAYLOAD';
  end if;

  for v_dim in select value from jsonb_array_elements(coalesce(payload->'dimensions', '[]'::jsonb))
  loop
    if coalesce(trim(v_dim->>'name'), '') = '' then
      raise exception using errcode = '22023', message = 'DIMENSION_NAME_REQUIRED';
    end if;
    v_pos_d := v_pos_d + 1;

    -- Código só vale se existir mesmo no catálogo: payload não inventa produto.
    select pd.code into v_dim_code from app.product_knowledge_dimensions pd
     where pd.code = nullif(trim(coalesce(v_dim->>'productCode', '')), '');

    insert into app.knowledge_dimensions
      (id, tenant_id, name, what_to_look_at, position, origin, product_code)
    values (coalesce((v_dim->>'id')::uuid, gen_random_uuid()), target_tenant_id,
            trim(v_dim->>'name'), nullif(trim(coalesce(v_dim->>'whatToLookAt', '')), ''), v_pos_d,
            case when v_dim_code is null then 'SALAO' else 'PRODUTO' end, v_dim_code)
    on conflict (id) do update
      set name = excluded.name,
          what_to_look_at = excluded.what_to_look_at,
          position = excluded.position,
          updated_at = statement_timestamp()
    returning id into v_dim_id;

    v_dim_ids := v_dim_ids || v_dim_id;
    v_pos_o := 0;

    for v_opt in select value from jsonb_array_elements(coalesce(v_dim->'options', '[]'::jsonb))
    loop
      if coalesce(trim(v_opt->>'label'), '') = '' then
        raise exception using errcode = '22023', message = 'OPTION_LABEL_REQUIRED';
      end if;
      v_pos_o := v_pos_o + 1;

      select po.code into v_opt_code from app.product_knowledge_options po
       where po.code = nullif(trim(coalesce(v_opt->>'productCode', '')), '');

      insert into app.knowledge_options
        (id, tenant_id, dimension_id, label, description, position, origin, product_code)
      values (coalesce((v_opt->>'id')::uuid, gen_random_uuid()), target_tenant_id, v_dim_id,
              trim(v_opt->>'label'), nullif(trim(coalesce(v_opt->>'description', '')), ''), v_pos_o,
              case when v_opt_code is null then 'SALAO' else 'PRODUTO' end, v_opt_code)
      on conflict (id) do update
        set dimension_id = excluded.dimension_id,
            label = excluded.label,
            description = excluded.description,
            position = excluded.position,
            updated_at = statement_timestamp()
      returning id into v_opt_id;

      v_opt_ids := v_opt_ids || v_opt_id;
      v_pos_f := 0;

      for v_photo in select value from jsonb_array_elements(coalesce(v_opt->'photos', '[]'::jsonb))
      loop
        if coalesce(trim(v_photo->>'storagePath'), '') = '' then
          continue;
        end if;
        v_pos_f := v_pos_f + 1;

        insert into app.knowledge_reference_photos (id, tenant_id, option_id, storage_path, caption, position)
        values (coalesce((v_photo->>'id')::uuid, gen_random_uuid()), target_tenant_id, v_opt_id,
                trim(v_photo->>'storagePath'), nullif(trim(coalesce(v_photo->>'caption', '')), ''), v_pos_f)
        on conflict (tenant_id, storage_path) do update
          set option_id = excluded.option_id,
              caption = excluded.caption,
              position = excluded.position
        returning id into v_photo_id;

        v_photo_ids := v_photo_ids || v_photo_id;
      end loop;
    end loop;
  end loop;

  select coalesce(array_agg(f.storage_path), '{}')
    into v_orfaos
    from app.knowledge_reference_photos f
   where f.tenant_id = target_tenant_id and not (f.id = any(v_photo_ids));

  delete from app.knowledge_reference_photos f
   where f.tenant_id = target_tenant_id and not (f.id = any(v_photo_ids));
  delete from app.knowledge_options o
   where o.tenant_id = target_tenant_id and not (o.id = any(v_opt_ids));
  delete from app.knowledge_dimensions d
   where d.tenant_id = target_tenant_id and not (d.id = any(v_dim_ids));

  return jsonb_build_object(
    'ok', true,
    'dimensions', coalesce(array_length(v_dim_ids, 1), 0),
    'removedPaths', to_jsonb(v_orfaos)
  );
end;
$function$;

grant execute on function public.site_save_knowledge(text, text, uuid, jsonb) to service_role;

-- A tela de Cor recebe a mesma etiqueta.
create or replace function public.site_load_color_model(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return jsonb_build_object(
    'levels', coalesce((
      select jsonb_agg(jsonb_build_object(
               'level', l.level, 'name', l.name, 'underlyingPigment', l.underlying_pigment
             ) order by l.level)
        from app.tone_levels l
    ), '[]'::jsonb),
    'families', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'name', f.name, 'description', f.description,
               'needsWarmBase', f.needs_warm_base,
               'extraMinutes', f.extra_minutes, 'extraPriceMinor', f.extra_price_minor,
               'origin', f.origin,
               'rangeMin', r.min_level, 'rangeMax', r.max_level,
               'rangeFromPhotos', r.from_photos,
               'photos', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', ph.id, 'storagePath', ph.storage_path,
                          'caption', ph.caption,
                          'estimatedLevel', ph.estimated_level,
                          'levelSource', ph.level_source,
                          'readAt', ph.read_at, 'readError', ph.read_error
                        ) order by ph.position, ph.created_at)
                   from app.tone_family_photos ph where ph.family_id = f.id
               ), '[]'::jsonb)
             ) order by f.position, f.name)
        from app.tone_families f
        left join lateral app.tone_family_range(f.id) r on true
       where f.tenant_id = target_tenant_id and f.status = 'ACTIVE'
    ), '[]'::jsonb),
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'key', p.key, 'question', p.question, 'helper', p.helper,
               'unit', p.unit,
               'suggestedValue', p.suggested_value,
               'answerValue', p.answer_value,
               'answered', p.answer_value is not null,
               'answeredAt', p.answered_at
             ) order by p.position)
        from app.color_policies p
       where p.tenant_id = target_tenant_id
    ), '[]'::jsonb),
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', r.code, 'title', r.title, 'statement', r.statement
             ) order by r.position)
        from app.product_rules r
       where r.status = 'ACTIVE' and r.subject in ('COR', 'QUIMICA')
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_load_color_model(text, text, uuid) to service_role;
