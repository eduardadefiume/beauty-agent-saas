begin;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tenant-a@example.invalid', '', now(), now()),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tenant-b@example.invalid', '', now(), now());

insert into app.profiles (id, display_name)
values
  ('10000000-0000-0000-0000-000000000001', 'QA Tenant A'),
  ('20000000-0000-0000-0000-000000000002', 'QA Tenant B');

insert into app.tenants (id, display_name, slug)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'QA Tenant A', 'qa-tenant-a'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'QA Tenant B', 'qa-tenant-b');

insert into app.tenant_memberships (tenant_id, profile_id, role)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'OWNER'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'OWNER');

insert into app.units (tenant_id, name, timezone)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Unit A', 'America/Sao_Paulo'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Unit B', 'America/Sao_Paulo');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

do $$
declare
  visible_tenants integer;
  visible_units integer;
begin
  select count(*) into visible_tenants from app.tenants;
  select count(*) into visible_units from app.units;

  if visible_tenants <> 1 then
    raise exception 'RLS_TENANT_READ_FAILED: expected 1, got %', visible_tenants;
  end if;

  if visible_units <> 1 then
    raise exception 'RLS_UNIT_READ_FAILED: expected 1, got %', visible_units;
  end if;

  if exists (
    select 1
    from app.units
    where tenant_id = 'bbbbbbbb-0000-0000-0000-000000000002'
  ) then
    raise exception 'RLS_CROSS_TENANT_READ_FAILED';
  end if;
end;
$$;

do $$
begin
  begin
    insert into app.units (tenant_id, name, timezone)
    values ('bbbbbbbb-0000-0000-0000-000000000002', 'Forbidden Unit', 'America/Sao_Paulo');

    raise exception 'RLS_CROSS_TENANT_WRITE_WAS_ALLOWED';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;

reset role;
rollback;

select
  'RLS_SMOKE_OK' as result,
  has_function_privilege('anon', 'public.rls_auto_enable()', 'execute')
    as anon_can_execute_rls_auto_enable,
  has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute')
    as authenticated_can_execute_rls_auto_enable;
