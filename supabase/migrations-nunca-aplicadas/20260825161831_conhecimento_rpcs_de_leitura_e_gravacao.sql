-- RPCs do módulo Conhecimento: ler e gravar o vocabulário.
--
-- NOTA DE HISTÓRICO. No banco de desenvolvimento este arquivo corresponde a
-- três migrações aplicadas em sequência (`conhecimento_rpcs_e_limpeza_de_arquivo`,
-- `conhecimento_corrige_variavel_do_id_da_foto`,
-- `conhecimento_banco_informa_arquivo_orfao`), porque a primeira versão tinha
-- dois defeitos encontrados em teste. O repositório carrega a versão final,
-- que é o que um ambiente novo precisa executar. Os dois defeitos estão
-- descritos aqui porque explicam por que o código é assim:
--
-- 1. O laço das fotos usava a MESMA variável do id da opção para receber o id
--    da foto no RETURNING. A partir da segunda foto, as seguintes seriam
--    penduradas na opção errada. Variável própria (v_photo_id) resolve.
--
-- 2. Havia um gatilho que apagava o arquivo do balde quando a linha da foto
--    saía. O Storage do Supabase RECUSA deleção direta em storage.objects por
--    SQL (trigger protect_delete) — e a recusa está certa, porque apagar a
--    linha sem passar pela API deixaria o arquivo real no balde, invisível e
--    ocupando espaço. A responsabilidade se inverteu: o banco não apaga
--    arquivo, ele DECLARA quais ficaram órfãos em `removedPaths`, e quem sabe
--    falar com o Storage apaga. Se essa limpeza falhar, o pior caso é arquivo
--    sobrando — nunca foto sumindo do cadastro.

-- Quem pertence a um tenant. private.require_site_tenant estoura quando não
-- pertence, o que serve para RPC mas não para política de storage, que precisa
-- de um booleano.
create or replace function app.email_belongs_to_tenant(p_email text, p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, pg_catalog
as $$
  select exists (
    select 1 from app.site_identities i
     where i.tenant_id = p_tenant_id
       and i.email_normalized = lower(trim(coalesce(p_email, '')))
       and i.status = 'ACTIVE'
  );
$$;

revoke all on function app.email_belongs_to_tenant(text, uuid) from public, anon;

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
               'options', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', o.id,
                          'label', o.label,
                          'description', o.description,
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
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_load_knowledge(text, text, uuid) to service_role;

-- Substitui o vocabulário inteiro, no mesmo espírito do rascunho de
-- configuração. Ids vindos no payload são preservados, para que a foto já
-- enviada continue pendurada na opção certa.
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

    insert into app.knowledge_dimensions (id, tenant_id, name, what_to_look_at, position)
    values (coalesce((v_dim->>'id')::uuid, gen_random_uuid()), target_tenant_id,
            trim(v_dim->>'name'), nullif(trim(coalesce(v_dim->>'whatToLookAt', '')), ''), v_pos_d)
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

      insert into app.knowledge_options (id, tenant_id, dimension_id, label, description, position)
      values (coalesce((v_opt->>'id')::uuid, gen_random_uuid()), target_tenant_id, v_dim_id,
              trim(v_opt->>'label'), nullif(trim(coalesce(v_opt->>'description', '')), ''), v_pos_o)
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

  -- Guarda o caminho ANTES de apagar a linha: depois do delete não há mais de
  -- onde tirar essa informação.
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
