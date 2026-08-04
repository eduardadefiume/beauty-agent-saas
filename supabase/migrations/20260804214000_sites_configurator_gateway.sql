begin;

create table app.site_identities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete cascade,
  site_project_id text not null check (length(trim(site_project_id)) between 8 and 160),
  email_normalized text not null check (email_normalized = lower(trim(email_normalized))),
  role app.tenant_role not null default 'OWNER',
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, site_project_id, email_normalized)
);

create index site_identities_lookup_idx
  on app.site_identities (site_project_id, email_normalized, tenant_id)
  where status = 'ACTIVE';

create trigger site_identities_touch_updated_at
before update on app.site_identities
for each row execute function private.touch_updated_at();

alter table app.site_identities enable row level security;
alter table app.site_identities force row level security;

revoke all on app.site_identities from public, anon, authenticated;
grant select, insert, update, delete on app.site_identities to service_role;

create or replace function private.require_site_tenant(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  allowed_roles app.tenant_role[] default null
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if nullif(trim(target_site_project_id), '') is null
     or nullif(trim(target_email), '') is null
     or target_tenant_id is null
     or not exists (
       select 1
         from app.site_identities identity_record
        where identity_record.site_project_id = target_site_project_id
          and identity_record.email_normalized = lower(trim(target_email))
          and identity_record.tenant_id = target_tenant_id
          and identity_record.status = 'ACTIVE'
          and (
            allowed_roles is null
            or identity_record.role = any(allowed_roles)
          )
     ) then
    raise exception using errcode = '42501', message = 'SITE_TENANT_NOT_ACCESSIBLE';
  end if;
end;
$$;

create or replace function public.site_list_tenants(
  target_site_project_id text,
  target_email text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'tenantId', tenant.id,
        'tenantName', tenant.display_name,
        'tenantSlug', tenant.slug,
        'unitId', unit_record.id,
        'unitName', unit_record.name,
        'timezone', unit_record.timezone,
        'draftId', draft.id,
        'revision', draft.revision,
        'status', coalesce(draft.status::text, 'NOT_STARTED'),
        'activeConfigurationVersionId', unit_record.active_configuration_version_id
      )
      order by tenant.display_name, unit_record.name
    ),
    '[]'::jsonb
  )
    from app.site_identities identity_record
    join app.tenants tenant
      on tenant.id = identity_record.tenant_id
     and tenant.status = 'ACTIVE'
    join app.units unit_record
      on unit_record.tenant_id = tenant.id
     and unit_record.status = 'ACTIVE'
    left join lateral (
      select configuration_draft.id, configuration_draft.revision, configuration_draft.status
        from app.configuration_drafts configuration_draft
       where configuration_draft.tenant_id = tenant.id
         and configuration_draft.unit_id = unit_record.id
       order by
         (configuration_draft.status = 'DRAFT') desc,
         configuration_draft.revision desc
       limit 1
    ) draft on true
   where identity_record.site_project_id = target_site_project_id
     and identity_record.email_normalized = lower(trim(target_email))
     and identity_record.status = 'ACTIVE'
$$;

create or replace function public.site_load_configuration(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  unit_record app.units%rowtype;
  draft_record app.configuration_drafts%rowtype;
  readiness_value jsonb;
  snapshot_value jsonb;
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role, 'OPERATOR'::app.tenant_role, 'VIEWER'::app.tenant_role]
  );

  select unit_value.*
    into unit_record
    from app.units unit_value
   where unit_value.tenant_id = target_tenant_id
     and unit_value.status = 'ACTIVE'
   order by unit_value.created_at
   limit 1;

  if unit_record.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_UNIT_NOT_FOUND';
  end if;

  select configuration_draft.*
    into draft_record
    from app.configuration_drafts configuration_draft
   where configuration_draft.tenant_id = target_tenant_id
     and configuration_draft.unit_id = unit_record.id
   order by
     (configuration_draft.status = 'DRAFT') desc,
     configuration_draft.revision desc
   limit 1;

  if draft_record.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_CONFIGURATION_NOT_FOUND';
  end if;

  snapshot_value := private.build_configuration_snapshot(draft_record.id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code', readiness.code,
        'entityType', readiness.entity_type,
        'entityId', readiness.entity_id,
        'fieldPath', readiness.field_path
      )
      order by readiness.code, readiness.entity_type, readiness.entity_id
    ),
    '[]'::jsonb
  )
    into readiness_value
    from private.configuration_readiness(draft_record.id) readiness;

  return jsonb_build_object(
    'tenant', jsonb_build_object(
      'id', target_tenant_id,
      'name', (select tenant.display_name from app.tenants tenant where tenant.id = target_tenant_id)
    ),
    'unit', jsonb_build_object(
      'id', unit_record.id,
      'name', unit_record.name,
      'timezone', unit_record.timezone
    ),
    'draft', jsonb_build_object(
      'id', draft_record.id,
      'revision', draft_record.revision,
      'status', draft_record.status
    ),
    'configuration', snapshot_value,
    'readiness', readiness_value
  );
end;
$$;

create or replace function public.site_replace_configuration(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  expected_revision integer,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft_record app.configuration_drafts%rowtype;
  hour_item jsonb;
  skill_item jsonb;
  member_item jsonb;
  availability_item jsonb;
  resource_type_item jsonb;
  resource_item jsonb;
  service_item jsonb;
  variation_item jsonb;
  step_item jsonb;
  requirement_item jsonb;
  member_id_value uuid;
  service_id_value uuid;
  step_id_value uuid;
  resource_type_id_value uuid;
  skill_id_value uuid;
  next_revision integer;
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if jsonb_typeof(payload) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_CONFIGURATION_PAYLOAD';
  end if;

  select configuration_draft.*
    into draft_record
    from app.configuration_drafts configuration_draft
   where configuration_draft.tenant_id = target_tenant_id
     and configuration_draft.status = 'DRAFT'
   order by configuration_draft.revision desc
   limit 1
   for update;

  if draft_record.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_DRAFT_NOT_FOUND';
  end if;

  if draft_record.revision <> expected_revision then
    raise exception using errcode = '40001', message = 'CONFIGURATION_REVISION_CONFLICT';
  end if;

  update app.units
     set name = coalesce(nullif(trim(payload #>> '{unit,name}'), ''), name),
         timezone = coalesce(nullif(trim(payload #>> '{unit,timezone}'), ''), timezone)
   where id = draft_record.unit_id
     and tenant_id = draft_record.tenant_id;

  delete from app.service_step_resource_requirements where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.service_step_skill_requirements where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.service_steps where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.service_variations where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.services where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.resources where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.resource_types where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.member_availability where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.member_skills where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.team_members where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.skills where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.unit_service_limits where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.operating_hours where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;

  for hour_item in select value from jsonb_array_elements(coalesce(payload->'operatingHours', '[]'::jsonb))
  loop
    insert into app.operating_hours (
      tenant_id, configuration_draft_id, weekday, starts_at, ends_at
    ) values (
      target_tenant_id,
      draft_record.id,
      (hour_item->>'weekday')::smallint,
      (hour_item->>'startsAt')::time,
      (hour_item->>'endsAt')::time
    );

    insert into app.unit_service_limits (
      tenant_id, configuration_draft_id, weekday, latest_end_time
    ) values (
      target_tenant_id,
      draft_record.id,
      (hour_item->>'weekday')::smallint,
      coalesce(nullif(hour_item->>'latestEndTime', '')::time, (hour_item->>'endsAt')::time)
    );
  end loop;

  for skill_item in select value from jsonb_array_elements(coalesce(payload->'skills', '[]'::jsonb))
  loop
    insert into app.skills (tenant_id, configuration_draft_id, name)
    values (target_tenant_id, draft_record.id, trim(skill_item #>> '{}'));
  end loop;

  for member_item in select value from jsonb_array_elements(coalesce(payload->'teamMembers', '[]'::jsonb))
  loop
    insert into app.team_members (
      tenant_id, configuration_draft_id, name, member_type, availability_mode
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(member_item->>'name'),
      coalesce(nullif(member_item->>'memberType', ''), 'PROFESSIONAL'),
      coalesce(nullif(member_item->>'availabilityMode', ''), 'FIXED')::app.availability_mode
    )
    returning id into member_id_value;

    for skill_item in select value from jsonb_array_elements(coalesce(member_item->'skillNames', '[]'::jsonb))
    loop
      select skill.id into skill_id_value
        from app.skills skill
       where skill.tenant_id = target_tenant_id
         and skill.configuration_draft_id = draft_record.id
         and skill.name = trim(skill_item #>> '{}');

      if skill_id_value is null then
        raise exception using errcode = '23503', message = 'MEMBER_SKILL_NOT_FOUND';
      end if;

      insert into app.member_skills (
        tenant_id, configuration_draft_id, member_id, skill_id
      ) values (
        target_tenant_id, draft_record.id, member_id_value, skill_id_value
      );
    end loop;

    for availability_item in select value from jsonb_array_elements(coalesce(member_item->'availability', '[]'::jsonb))
    loop
      insert into app.member_availability (
        tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at
      ) values (
        target_tenant_id,
        draft_record.id,
        member_id_value,
        (availability_item->>'weekday')::smallint,
        (availability_item->>'startsAt')::time,
        (availability_item->>'endsAt')::time
      );
    end loop;
  end loop;

  for resource_type_item in select value from jsonb_array_elements(coalesce(payload->'resourceTypes', '[]'::jsonb))
  loop
    insert into app.resource_types (
      tenant_id, configuration_draft_id, name, description
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(resource_type_item->>'name'),
      nullif(trim(coalesce(resource_type_item->>'description', '')), '')
    )
    returning id into resource_type_id_value;

    for resource_item in select value from jsonb_array_elements(coalesce(resource_type_item->'resources', '[]'::jsonb))
    loop
      insert into app.resources (
        tenant_id, configuration_draft_id, resource_type_id, name, capacity
      ) values (
        target_tenant_id,
        draft_record.id,
        resource_type_id_value,
        trim(resource_item->>'name'),
        coalesce((resource_item->>'capacity')::integer, 1)
      );
    end loop;
  end loop;

  for service_item in select value from jsonb_array_elements(coalesce(payload->'services', '[]'::jsonb))
  loop
    insert into app.services (
      tenant_id, configuration_draft_id, name, description, kind,
      base_price_minor, currency, bookable
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(service_item->>'name'),
      nullif(trim(coalesce(service_item->>'description', '')), ''),
      coalesce(nullif(service_item->>'kind', ''), 'SIMPLE')::app.service_kind,
      nullif(service_item->>'basePriceMinor', '')::integer,
      'BRL',
      coalesce((service_item->>'bookable')::boolean, true)
    )
    returning id into service_id_value;

    for variation_item in select value from jsonb_array_elements(coalesce(service_item->'variations', '[]'::jsonb))
    loop
      insert into app.service_variations (
        tenant_id, configuration_draft_id, service_id, name,
        classification_values, price_minor
      ) values (
        target_tenant_id,
        draft_record.id,
        service_id_value,
        trim(variation_item->>'name'),
        coalesce(variation_item->'classificationValues', '{}'::jsonb),
        nullif(variation_item->>'priceMinor', '')::integer
      );
    end loop;

    for step_item in select value from jsonb_array_elements(coalesce(service_item->'steps', '[]'::jsonb))
    loop
      insert into app.service_steps (
        tenant_id, configuration_draft_id, service_id, name, position,
        duration_minutes, kind, customer_presence_required, releases_member
      ) values (
        target_tenant_id,
        draft_record.id,
        service_id_value,
        trim(step_item->>'name'),
        (step_item->>'position')::integer,
        (step_item->>'durationMinutes')::integer,
        coalesce(nullif(step_item->>'kind', ''), 'ACTIVE')::app.step_kind,
        coalesce((step_item->>'customerPresenceRequired')::boolean, true),
        coalesce((step_item->>'releasesMember')::boolean, false)
      )
      returning id into step_id_value;

      for skill_item in select value from jsonb_array_elements(coalesce(step_item->'skillNames', '[]'::jsonb))
      loop
        select skill.id into skill_id_value
          from app.skills skill
         where skill.tenant_id = target_tenant_id
           and skill.configuration_draft_id = draft_record.id
           and skill.name = trim(skill_item #>> '{}');

        if skill_id_value is null then
          raise exception using errcode = '23503', message = 'STEP_SKILL_NOT_FOUND';
        end if;

        insert into app.service_step_skill_requirements (
          tenant_id, configuration_draft_id, step_id, skill_id, quantity
        ) values (
          target_tenant_id, draft_record.id, step_id_value, skill_id_value, 1
        );
      end loop;

      for requirement_item in select value from jsonb_array_elements(coalesce(step_item->'resourceRequirements', '[]'::jsonb))
      loop
        select resource_type.id into resource_type_id_value
          from app.resource_types resource_type
         where resource_type.tenant_id = target_tenant_id
           and resource_type.configuration_draft_id = draft_record.id
           and resource_type.name = trim(requirement_item->>'resourceTypeName');

        if resource_type_id_value is null then
          raise exception using errcode = '23503', message = 'STEP_RESOURCE_TYPE_NOT_FOUND';
        end if;

        insert into app.service_step_resource_requirements (
          tenant_id, configuration_draft_id, step_id, resource_type_id,
          quantity, retain_until_service_end
        ) values (
          target_tenant_id,
          draft_record.id,
          step_id_value,
          resource_type_id_value,
          coalesce((requirement_item->>'quantity')::integer, 1),
          coalesce((requirement_item->>'retainUntilServiceEnd')::boolean, false)
        );
      end loop;
    end loop;
  end loop;

  next_revision := draft_record.revision + 1;

  update app.configuration_drafts
     set revision = next_revision,
         final_message_template = nullif(trim(coalesce(payload->>'finalMessageTemplate', '')), ''),
         deposit_enabled = false,
         channel_mode = 'RESTRICTED',
         updated_by = null
   where id = draft_record.id;

  return public.site_load_configuration(
    target_site_project_id,
    target_email,
    target_tenant_id
  );
end;
$$;

create or replace function public.site_publish_configuration(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  expected_revision integer,
  target_correlation_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft_record app.configuration_drafts%rowtype;
  unit_record app.units%rowtype;
  next_version integer;
  snapshot_value jsonb;
  hash_value text;
  new_version_id uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if target_correlation_id is null
     or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select configuration_draft.*
    into draft_record
    from app.configuration_drafts configuration_draft
   where configuration_draft.tenant_id = target_tenant_id
     and configuration_draft.status = 'DRAFT'
   order by configuration_draft.revision desc
   limit 1
   for update;

  if draft_record.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_DRAFT_NOT_FOUND';
  end if;

  if draft_record.revision <> expected_revision then
    raise exception using errcode = '40001', message = 'CONFIGURATION_REVISION_CONFLICT';
  end if;

  if exists (select 1 from private.configuration_readiness(draft_record.id)) then
    raise exception using errcode = '23514', message = 'CONFIGURATION_NOT_READY';
  end if;

  select unit_value.*
    into unit_record
    from app.units unit_value
   where unit_value.id = draft_record.unit_id
     and unit_value.tenant_id = draft_record.tenant_id
   for update;

  select coalesce(max(version_record.version_number), 0) + 1
    into next_version
    from app.configuration_versions version_record
   where version_record.tenant_id = draft_record.tenant_id
     and version_record.unit_id = draft_record.unit_id;

  snapshot_value := private.build_configuration_snapshot(draft_record.id);
  hash_value := encode(extensions.digest(snapshot_value::text, 'sha256'), 'hex');

  insert into app.configuration_versions (
    tenant_id, unit_id, source_draft_id, version_number,
    snapshot, snapshot_hash, published_by
  ) values (
    draft_record.tenant_id, draft_record.unit_id, draft_record.id,
    next_version, snapshot_value, hash_value, null
  )
  returning id into new_version_id;

  update app.configuration_drafts
     set status = 'PUBLISHED',
         updated_by = null,
         updated_at = statement_timestamp()
   where id = draft_record.id;

  update app.units
     set active_configuration_version_id = new_version_id,
         updated_at = statement_timestamp()
   where id = draft_record.unit_id
     and tenant_id = draft_record.tenant_id;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id,
    configuration_version_id, correlation_id, result, metadata_minimized
  ) values (
    draft_record.tenant_id, 'SYSTEM', null, 'CONFIGURATION_PUBLISHED',
    'configuration_version', new_version_id, new_version_id,
    target_correlation_id, 'SUCCESS',
    jsonb_build_object(
      'versionNumber', next_version,
      'snapshotHash', hash_value,
      'channel', 'SITES'
    )
  );

  return jsonb_build_object(
    'configurationVersionId', new_version_id,
    'versionNumber', next_version,
    'snapshotHash', hash_value
  );
end;
$$;

revoke all on function private.require_site_tenant(text, text, uuid, app.tenant_role[])
  from public, anon, authenticated, service_role;
revoke all on function public.site_list_tenants(text, text)
  from public, anon, authenticated;
revoke all on function public.site_load_configuration(text, text, uuid)
  from public, anon, authenticated;
revoke all on function public.site_replace_configuration(text, text, uuid, integer, jsonb)
  from public, anon, authenticated;
revoke all on function public.site_publish_configuration(text, text, uuid, integer, text)
  from public, anon, authenticated;

grant execute on function public.site_list_tenants(text, text) to service_role;
grant execute on function public.site_load_configuration(text, text, uuid) to service_role;
grant execute on function public.site_replace_configuration(text, text, uuid, integer, jsonb) to service_role;
grant execute on function public.site_publish_configuration(text, text, uuid, integer, text) to service_role;

comment on table app.site_identities is
  'Server-side identity mapping for Sites SIWC. Never expose directly to browsers.';
comment on function public.site_replace_configuration(text, text, uuid, integer, jsonb) is
  'Atomically replaces one open draft from a server-authenticated Sites request.';

commit;
