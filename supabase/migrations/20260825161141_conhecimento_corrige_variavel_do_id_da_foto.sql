-- Correção: a versão anterior usava v_opt_id para receber o id da foto no
-- RETURNING, o que sobrescrevia o id da opção no meio do laço. A partir da
-- segunda foto, as seguintes seriam penduradas na opção errada. Variável
-- própria para a foto resolve.
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

  delete from app.knowledge_reference_photos f
   where f.tenant_id = target_tenant_id and not (f.id = any(v_photo_ids));
  delete from app.knowledge_options o
   where o.tenant_id = target_tenant_id and not (o.id = any(v_opt_ids));
  delete from app.knowledge_dimensions d
   where d.tenant_id = target_tenant_id and not (d.id = any(v_dim_ids));

  return jsonb_build_object('ok', true, 'dimensions', coalesce(array_length(v_dim_ids, 1), 0));
end;
$function$;

grant execute on function public.site_save_knowledge(text, text, uuid, jsonb) to service_role;