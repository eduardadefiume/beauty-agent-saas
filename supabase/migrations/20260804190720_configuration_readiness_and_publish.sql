begin;

create schema if not exists api;
revoke all on schema api from public, anon;
grant usage on schema api to authenticated, service_role;

drop policy app_configuration_drafts_insert_admin on app.configuration_drafts;
drop policy app_configuration_drafts_update_admin on app.configuration_drafts;
drop policy app_configuration_drafts_delete_admin on app.configuration_drafts;

create policy app_configuration_drafts_insert_admin
  on app.configuration_drafts
  for insert to authenticated
  with check (
    status = 'DRAFT'
    and private.has_tenant_role(
      tenant_id,
      array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
    )
  );

create policy app_configuration_drafts_update_admin
  on app.configuration_drafts
  for update to authenticated
  using (
    status = 'DRAFT'
    and private.has_tenant_role(
      tenant_id,
      array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
    )
  )
  with check (
    status = 'DRAFT'
    and private.has_tenant_role(
      tenant_id,
      array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
    )
  );

create policy app_configuration_drafts_delete_admin
  on app.configuration_drafts
  for delete to authenticated
  using (
    status = 'DRAFT'
    and private.has_tenant_role(
      tenant_id,
      array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
    )
  );

create or replace function private.assert_configuration_draft_open()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft_status app.configuration_status;
  draft_id uuid;
  row_tenant_id uuid;
begin
  draft_id := case when tg_op = 'DELETE' then old.configuration_draft_id else new.configuration_draft_id end;
  row_tenant_id := case when tg_op = 'DELETE' then old.tenant_id else new.tenant_id end;

  select draft.status
    into draft_status
    from app.configuration_drafts draft
   where draft.id = draft_id
     and draft.tenant_id = row_tenant_id;

  if draft_status is distinct from 'DRAFT'::app.configuration_status then
    raise exception using
      errcode = '55000',
      message = 'CONFIGURATION_DRAFT_NOT_OPEN';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function private.assert_configuration_draft_open()
  from public, anon, authenticated, service_role;

do $$
declare
  target_table regclass;
  mutable_tables regclass[] := array[
    'app.operating_hours'::regclass,
    'app.unit_service_limits'::regclass,
    'app.skills'::regclass,
    'app.team_members'::regclass,
    'app.member_skills'::regclass,
    'app.member_availability'::regclass,
    'app.resource_types'::regclass,
    'app.resources'::regclass,
    'app.services'::regclass,
    'app.service_variations'::regclass,
    'app.service_steps'::regclass,
    'app.service_step_skill_requirements'::regclass,
    'app.service_step_resource_requirements'::regclass
  ];
begin
  foreach target_table in array mutable_tables loop
    execute format(
      'create trigger %I before insert or update or delete on %s for each row execute function private.assert_configuration_draft_open()',
      replace(target_table::text, '.', '_') || '_draft_open',
      target_table
    );
  end loop;
end;
$$;

create or replace function private.configuration_readiness(target_draft_id uuid)
returns table (
  code text,
  entity_type text,
  entity_id uuid,
  field_path text
)
language sql
stable
security definer
set search_path = ''
as $$
  with draft as (
    select d.id, d.tenant_id, d.unit_id, d.final_message_template
      from app.configuration_drafts d
     where d.id = target_draft_id
  )
  select 'UNIT_TIMEZONE_MISSING', 'unit', u.id, 'unit.timezone'
    from draft d
    join app.units u on u.id = d.unit_id and u.tenant_id = d.tenant_id
   where not exists (
     select 1 from pg_catalog.pg_timezone_names tz where tz.name = u.timezone
   )
  union all
  select 'OPERATING_HOURS_MISSING', 'configuration_draft', d.id, 'operatingHours'
    from draft d
   where not exists (
     select 1 from app.operating_hours h
      where h.tenant_id = d.tenant_id and h.configuration_draft_id = d.id
   )
  union all
  select 'LATEST_END_MISSING', 'configuration_draft', d.id, 'serviceLimits'
    from draft d
   where exists (
     select 1
       from app.operating_hours h
      where h.tenant_id = d.tenant_id
        and h.configuration_draft_id = d.id
        and not exists (
          select 1
            from app.unit_service_limits l
           where l.tenant_id = h.tenant_id
             and l.configuration_draft_id = h.configuration_draft_id
             and l.weekday = h.weekday
        )
   )
  union all
  select 'NO_ACTIVE_MEMBER', 'configuration_draft', d.id, 'teamMembers'
    from draft d
   where not exists (
     select 1 from app.team_members m
      where m.tenant_id = d.tenant_id
        and m.configuration_draft_id = d.id
        and m.status = 'ACTIVE'
   )
  union all
  select 'MEMBER_AVAILABILITY_INVALID', 'team_member', m.id, 'teamMembers.availability'
    from draft d
    join app.team_members m
      on m.tenant_id = d.tenant_id and m.configuration_draft_id = d.id
   where m.status = 'ACTIVE'
     and m.availability_mode in ('FIXED', 'HYBRID')
     and not exists (
       select 1 from app.member_availability a
        where a.tenant_id = m.tenant_id
          and a.configuration_draft_id = m.configuration_draft_id
          and a.member_id = m.id
     )
  union all
  select 'NO_BOOKABLE_SERVICE', 'configuration_draft', d.id, 'services'
    from draft d
   where not exists (
     select 1 from app.services s
      where s.tenant_id = d.tenant_id
        and s.configuration_draft_id = d.id
        and s.status = 'ACTIVE'
        and s.bookable
   )
  union all
  select 'SERVICE_HAS_NO_STEPS', 'service', s.id, 'services.steps'
    from draft d
    join app.services s
      on s.tenant_id = d.tenant_id and s.configuration_draft_id = d.id
   where s.status = 'ACTIVE'
     and s.bookable
     and not exists (
       select 1 from app.service_steps st
        where st.tenant_id = s.tenant_id
          and st.configuration_draft_id = s.configuration_draft_id
          and st.service_id = s.id
     )
  union all
  select 'STEP_HAS_NO_QUALIFIED_MEMBER', 'service_step', st.id, 'services.steps.skills'
    from draft d
    join app.service_steps st
      on st.tenant_id = d.tenant_id and st.configuration_draft_id = d.id
   where st.kind = 'ACTIVE'
     and (
       not exists (
         select 1 from app.service_step_skill_requirements req
          where req.tenant_id = st.tenant_id
            and req.configuration_draft_id = st.configuration_draft_id
            and req.step_id = st.id
       )
       or exists (
         select 1
           from app.service_step_skill_requirements req
          where req.tenant_id = st.tenant_id
            and req.configuration_draft_id = st.configuration_draft_id
            and req.step_id = st.id
            and (
              select count(*)
                from app.member_skills ms
                join app.team_members m
                  on m.tenant_id = ms.tenant_id
                 and m.configuration_draft_id = ms.configuration_draft_id
                 and m.id = ms.member_id
                 and m.status = 'ACTIVE'
               where ms.tenant_id = req.tenant_id
                 and ms.configuration_draft_id = req.configuration_draft_id
                 and ms.skill_id = req.skill_id
            ) < req.quantity
       )
     )
  union all
  select 'RESOURCE_CAPACITY_MISSING', 'service_step', st.id, 'services.steps.resources'
    from draft d
    join app.service_steps st
      on st.tenant_id = d.tenant_id and st.configuration_draft_id = d.id
    join app.service_step_resource_requirements req
      on req.tenant_id = st.tenant_id
     and req.configuration_draft_id = st.configuration_draft_id
     and req.step_id = st.id
   where (
     select coalesce(sum(r.capacity), 0)
       from app.resources r
      where r.tenant_id = req.tenant_id
        and r.configuration_draft_id = req.configuration_draft_id
        and r.resource_type_id = req.resource_type_id
        and r.status = 'ACTIVE'
   ) < req.quantity
  union all
  select 'FINAL_MESSAGE_MISSING', 'configuration_draft', d.id, 'finalMessageTemplate'
    from draft d
   where nullif(trim(d.final_message_template), '') is null
$$;

create or replace function api.check_configuration_readiness(target_draft_id uuid)
returns table (
  code text,
  entity_type text,
  entity_id uuid,
  field_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_tenant_id uuid;
begin
  select d.tenant_id into target_tenant_id
    from app.configuration_drafts d
   where d.id = target_draft_id;

  if target_tenant_id is null
     or not private.has_tenant_role(target_tenant_id) then
    raise exception using errcode = '42501', message = 'CONFIGURATION_NOT_ACCESSIBLE';
  end if;

  return query
    select readiness.code, readiness.entity_type, readiness.entity_id, readiness.field_path
      from private.configuration_readiness(target_draft_id) readiness
     order by readiness.code, readiness.entity_type, readiness.entity_id;
end;
$$;

create or replace function private.build_configuration_snapshot(target_draft_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'schemaVersion', 1,
    'tenantId', d.tenant_id,
    'unitId', d.unit_id,
    'sourceDraftId', d.id,
    'sourceRevision', d.revision,
    'depositEnabled', d.deposit_enabled,
    'channelMode', d.channel_mode,
    'finalMessageTemplate', d.final_message_template,
    'operatingHours', coalesce((
      select jsonb_agg(to_jsonb(h) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by h.weekday, h.starts_at, h.id)
        from app.operating_hours h
       where h.tenant_id = d.tenant_id and h.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'serviceLimits', coalesce((
      select jsonb_agg(to_jsonb(l) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by l.weekday, l.id)
        from app.unit_service_limits l
       where l.tenant_id = d.tenant_id and l.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'skills', coalesce((
      select jsonb_agg(to_jsonb(s) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by s.name, s.id)
        from app.skills s
       where s.tenant_id = d.tenant_id and s.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'teamMembers', coalesce((
      select jsonb_agg(
        (to_jsonb(m) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at')
        || jsonb_build_object(
          'skillIds', coalesce((
            select jsonb_agg(ms.skill_id order by ms.priority, ms.skill_id)
              from app.member_skills ms
             where ms.tenant_id = m.tenant_id
               and ms.configuration_draft_id = m.configuration_draft_id
               and ms.member_id = m.id
          ), '[]'::jsonb),
          'availability', coalesce((
            select jsonb_agg(to_jsonb(a) - 'tenant_id' - 'configuration_draft_id' - 'member_id' - 'created_at' - 'updated_at'
                             order by a.weekday, a.starts_at, a.id)
              from app.member_availability a
             where a.tenant_id = m.tenant_id
               and a.configuration_draft_id = m.configuration_draft_id
               and a.member_id = m.id
          ), '[]'::jsonb)
        )
        order by m.name, m.id
      )
        from app.team_members m
       where m.tenant_id = d.tenant_id and m.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'resourceTypes', coalesce((
      select jsonb_agg(
        (to_jsonb(rt) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at')
        || jsonb_build_object(
          'resources', coalesce((
            select jsonb_agg(to_jsonb(r) - 'tenant_id' - 'configuration_draft_id' - 'resource_type_id' - 'created_at' - 'updated_at'
                             order by r.name, r.id)
              from app.resources r
             where r.tenant_id = rt.tenant_id
               and r.configuration_draft_id = rt.configuration_draft_id
               and r.resource_type_id = rt.id
          ), '[]'::jsonb)
        )
        order by rt.name, rt.id
      )
        from app.resource_types rt
       where rt.tenant_id = d.tenant_id and rt.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'services', coalesce((
      select jsonb_agg(
        (to_jsonb(svc) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at')
        || jsonb_build_object(
          'variations', coalesce((
            select jsonb_agg(to_jsonb(v) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at'
                             order by v.name, v.id)
              from app.service_variations v
             where v.tenant_id = svc.tenant_id
               and v.configuration_draft_id = svc.configuration_draft_id
               and v.service_id = svc.id
          ), '[]'::jsonb),
          'steps', coalesce((
            select jsonb_agg(
              (to_jsonb(st) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at')
              || jsonb_build_object(
                'skillRequirements', coalesce((
                  select jsonb_agg(to_jsonb(sr) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'created_at'
                                   order by sr.skill_id)
                    from app.service_step_skill_requirements sr
                   where sr.tenant_id = st.tenant_id
                     and sr.configuration_draft_id = st.configuration_draft_id
                     and sr.step_id = st.id
                ), '[]'::jsonb),
                'resourceRequirements', coalesce((
                  select jsonb_agg(to_jsonb(rr) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'created_at'
                                   order by rr.resource_type_id)
                    from app.service_step_resource_requirements rr
                   where rr.tenant_id = st.tenant_id
                     and rr.configuration_draft_id = st.configuration_draft_id
                     and rr.step_id = st.id
                ), '[]'::jsonb)
              )
              order by st.position, st.id
            )
              from app.service_steps st
             where st.tenant_id = svc.tenant_id
               and st.configuration_draft_id = svc.configuration_draft_id
               and st.service_id = svc.id
          ), '[]'::jsonb)
        )
        order by svc.name, svc.id
      )
        from app.services svc
       where svc.tenant_id = d.tenant_id and svc.configuration_draft_id = d.id
    ), '[]'::jsonb)
  )
    from app.configuration_drafts d
   where d.id = target_draft_id
$$;

create or replace function api.publish_configuration(
  target_draft_id uuid,
  expected_revision integer,
  target_correlation_id text
)
returns table (
  configuration_version_id uuid,
  published_version_number integer,
  published_snapshot_hash text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  draft_record app.configuration_drafts%rowtype;
  next_version integer;
  snapshot_value jsonb;
  hash_value text;
  new_version_id uuid;
begin
  if target_correlation_id is null
     or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select d.* into draft_record
    from app.configuration_drafts d
   where d.id = target_draft_id
   for update;

  if draft_record.id is null
     or not private.has_tenant_role(
       draft_record.tenant_id,
       array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
     ) then
    raise exception using errcode = '42501', message = 'CONFIGURATION_NOT_ACCESSIBLE';
  end if;

  if draft_record.status <> 'DRAFT' then
    raise exception using errcode = '55000', message = 'CONFIGURATION_DRAFT_NOT_OPEN';
  end if;

  if draft_record.revision <> expected_revision then
    raise exception using errcode = '40001', message = 'CONFIGURATION_REVISION_CONFLICT';
  end if;

  if exists (select 1 from private.configuration_readiness(target_draft_id)) then
    raise exception using errcode = '23514', message = 'CONFIGURATION_NOT_READY';
  end if;

  perform 1
    from app.units u
   where u.id = draft_record.unit_id and u.tenant_id = draft_record.tenant_id
   for update;

  select coalesce(max(v.version_number), 0) + 1
    into next_version
    from app.configuration_versions v
   where v.tenant_id = draft_record.tenant_id
     and v.unit_id = draft_record.unit_id;

  snapshot_value := private.build_configuration_snapshot(target_draft_id);
  hash_value := encode(extensions.digest(snapshot_value::text, 'sha256'), 'hex');

  insert into app.configuration_versions (
    tenant_id,
    unit_id,
    source_draft_id,
    version_number,
    snapshot,
    snapshot_hash,
    published_by
  ) values (
    draft_record.tenant_id,
    draft_record.unit_id,
    draft_record.id,
    next_version,
    snapshot_value,
    hash_value,
    auth.uid()
  )
  returning id into new_version_id;

  update app.configuration_drafts
     set status = 'PUBLISHED',
         updated_by = auth.uid(),
         updated_at = statement_timestamp()
   where id = draft_record.id;

  update app.units
     set active_configuration_version_id = new_version_id,
         updated_at = statement_timestamp()
   where id = draft_record.unit_id and tenant_id = draft_record.tenant_id;

  insert into app.audit_logs (
    tenant_id,
    actor_type,
    actor_id,
    action,
    entity_type,
    entity_id,
    configuration_version_id,
    correlation_id,
    result,
    metadata_minimized
  ) values (
    draft_record.tenant_id,
    'USER',
    auth.uid(),
    'CONFIGURATION_PUBLISHED',
    'configuration_version',
    new_version_id,
    new_version_id,
    target_correlation_id,
    'SUCCESS',
    jsonb_build_object('versionNumber', next_version, 'snapshotHash', hash_value)
  );

  return query select new_version_id, next_version, hash_value;
end;
$$;

revoke all on function private.configuration_readiness(uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.build_configuration_snapshot(uuid)
  from public, anon, authenticated, service_role;
revoke all on function api.check_configuration_readiness(uuid)
  from public, anon, authenticated, service_role;
revoke all on function api.publish_configuration(uuid, integer, text)
  from public, anon, authenticated, service_role;

grant execute on function api.check_configuration_readiness(uuid)
  to authenticated, service_role;
grant execute on function api.publish_configuration(uuid, integer, text)
  to authenticated, service_role;

commit;
