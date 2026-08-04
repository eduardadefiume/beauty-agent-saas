begin;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('31000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'config-a@example.invalid', '', now(), now()),
  ('32000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'config-b@example.invalid', '', now(), now());

insert into app.profiles (id, display_name)
values
  ('31000000-0000-0000-0000-000000000001', 'Config QA A'),
  ('32000000-0000-0000-0000-000000000002', 'Config QA B');

insert into app.tenants (id, display_name, slug)
values
  ('ca000000-0000-0000-0000-000000000001', 'Config Tenant A', 'config-tenant-a'),
  ('cb000000-0000-0000-0000-000000000002', 'Config Tenant B', 'config-tenant-b');

insert into app.tenant_memberships (tenant_id, profile_id, role)
values
  ('ca000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001', 'OWNER'),
  ('cb000000-0000-0000-0000-000000000002', '32000000-0000-0000-0000-000000000002', 'OWNER');

insert into app.units (id, tenant_id, name, timezone)
values
  ('ca100000-0000-0000-0000-000000000001', 'ca000000-0000-0000-0000-000000000001', 'Config Unit A', 'America/Sao_Paulo'),
  ('cb100000-0000-0000-0000-000000000002', 'cb000000-0000-0000-0000-000000000002', 'Config Unit B', 'America/Sao_Paulo');

insert into app.configuration_drafts (id, tenant_id, unit_id)
values
  ('ca200000-0000-0000-0000-000000000001', 'ca000000-0000-0000-0000-000000000001', 'ca100000-0000-0000-0000-000000000001'),
  ('cb200000-0000-0000-0000-000000000002', 'cb000000-0000-0000-0000-000000000002', 'cb100000-0000-0000-0000-000000000002');

insert into app.skills (tenant_id, configuration_draft_id, name)
values
  ('ca000000-0000-0000-0000-000000000001', 'ca200000-0000-0000-0000-000000000001', 'Skill A'),
  ('cb000000-0000-0000-0000-000000000002', 'cb200000-0000-0000-0000-000000000002', 'Skill B');

do $$
begin
  begin
    insert into app.configuration_drafts (tenant_id, unit_id)
    values ('ca000000-0000-0000-0000-000000000001', 'cb100000-0000-0000-0000-000000000002');
    raise exception 'CROSS_TENANT_FOREIGN_KEY_WAS_ALLOWED';
  exception
    when foreign_key_violation then null;
  end;
end;
$$;

insert into app.configuration_versions (
  id, tenant_id, unit_id, source_draft_id, version_number, snapshot, snapshot_hash
) values (
  'ca300000-0000-0000-0000-000000000001',
  'ca000000-0000-0000-0000-000000000001',
  'ca100000-0000-0000-0000-000000000001',
  'ca200000-0000-0000-0000-000000000001',
  1,
  '{"schema_version":1}'::jsonb,
  repeat('0', 64)
);

do $$
begin
  begin
    update app.configuration_versions
       set snapshot = '{"schema_version":2}'::jsonb
     where id = 'ca300000-0000-0000-0000-000000000001';
    raise exception 'PUBLISHED_CONFIGURATION_WAS_MUTABLE';
  exception
    when object_not_in_prerequisite_state then null;
  end;
end;
$$;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"31000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

do $$
declare
  visible_drafts integer;
  visible_skills integer;
begin
  select count(*) into visible_drafts from app.configuration_drafts;
  select count(*) into visible_skills from app.skills;

  if visible_drafts <> 1 or visible_skills <> 1 then
    raise exception 'CONFIGURATION_RLS_READ_FAILED: drafts %, skills %', visible_drafts, visible_skills;
  end if;

  begin
    insert into app.skills (tenant_id, configuration_draft_id, name)
    values (
      'cb000000-0000-0000-0000-000000000002',
      'cb200000-0000-0000-0000-000000000002',
      'Forbidden Skill'
    );
    raise exception 'CONFIGURATION_RLS_CROSS_TENANT_WRITE_WAS_ALLOWED';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;

reset role;
rollback;

select 'CONFIGURATION_SMOKE_OK' as result;
