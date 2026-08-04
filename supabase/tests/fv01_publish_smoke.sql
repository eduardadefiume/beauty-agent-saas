begin;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values (
  '41000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'publish@example.invalid',
  '',
  now(),
  now()
);

insert into app.profiles (id, display_name)
values ('41000000-0000-0000-0000-000000000001', 'Publish QA');

insert into app.tenants (id, display_name, slug)
values ('da000000-0000-0000-0000-000000000001', 'Publish Tenant', 'publish-tenant');

insert into app.tenant_memberships (tenant_id, profile_id, role)
values (
  'da000000-0000-0000-0000-000000000001',
  '41000000-0000-0000-0000-000000000001',
  'OWNER'
);

insert into app.units (id, tenant_id, name, timezone)
values (
  'da100000-0000-0000-0000-000000000001',
  'da000000-0000-0000-0000-000000000001',
  'Publish Unit',
  'America/Sao_Paulo'
);

insert into app.configuration_drafts (
  id, tenant_id, unit_id, final_message_template
) values (
  'da200000-0000-0000-0000-000000000001',
  'da000000-0000-0000-0000-000000000001',
  'da100000-0000-0000-0000-000000000001',
  'Agendamento confirmado para {{startAt}}.'
);

insert into app.operating_hours (
  tenant_id, configuration_draft_id, weekday, starts_at, ends_at
) values (
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  1,
  '09:00',
  '18:00'
);

insert into app.unit_service_limits (
  tenant_id, configuration_draft_id, weekday, latest_end_time
) values (
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  1,
  '18:00'
);

insert into app.skills (id, tenant_id, configuration_draft_id, name)
values (
  'da300000-0000-0000-0000-000000000001',
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'Corte'
);

insert into app.team_members (
  id, tenant_id, configuration_draft_id, name
) values (
  'da400000-0000-0000-0000-000000000001',
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'Profissional'
);

insert into app.member_skills (
  tenant_id, configuration_draft_id, member_id, skill_id
) values (
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'da400000-0000-0000-0000-000000000001',
  'da300000-0000-0000-0000-000000000001'
);

insert into app.member_availability (
  tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at
) values (
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'da400000-0000-0000-0000-000000000001',
  1,
  '09:00',
  '18:00'
);

insert into app.resource_types (
  id, tenant_id, configuration_draft_id, name
) values (
  'da500000-0000-0000-0000-000000000001',
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'Cadeira'
);

insert into app.resources (
  tenant_id, configuration_draft_id, resource_type_id, name, capacity
) values (
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'da500000-0000-0000-0000-000000000001',
  'Cadeira 1',
  1
);

insert into app.services (
  id, tenant_id, configuration_draft_id, name, kind
) values (
  'da600000-0000-0000-0000-000000000001',
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'Corte',
  'SIMPLE'
);

insert into app.service_steps (
  id, tenant_id, configuration_draft_id, service_id, name, position, duration_minutes
) values (
  'da700000-0000-0000-0000-000000000001',
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'da600000-0000-0000-0000-000000000001',
  'Executar corte',
  1,
  45
);

insert into app.service_step_skill_requirements (
  tenant_id, configuration_draft_id, step_id, skill_id
) values (
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'da700000-0000-0000-0000-000000000001',
  'da300000-0000-0000-0000-000000000001'
);

insert into app.service_step_resource_requirements (
  tenant_id, configuration_draft_id, step_id, resource_type_id
) values (
  'da000000-0000-0000-0000-000000000001',
  'da200000-0000-0000-0000-000000000001',
  'da700000-0000-0000-0000-000000000001',
  'da500000-0000-0000-0000-000000000001'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"41000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

do $$
declare
  readiness_count integer;
  published_id uuid;
  published_number integer;
  published_hash text;
  active_version_id uuid;
begin
  select count(*) into readiness_count
    from api.check_configuration_readiness(
      'da200000-0000-0000-0000-000000000001'
    );

  if readiness_count <> 0 then
    raise exception 'READINESS_EXPECTED_ZERO_GOT_%', readiness_count;
  end if;

  select configuration_version_id, published_version_number, published_snapshot_hash
    into published_id, published_number, published_hash
    from api.publish_configuration(
      'da200000-0000-0000-0000-000000000001',
      1,
      'qa-publish-0001'
    );

  if published_number <> 1 or length(published_hash) <> 64 then
    raise exception 'PUBLISH_METADATA_INVALID';
  end if;

  select u.active_configuration_version_id into active_version_id
    from app.units u
   where u.id = 'da100000-0000-0000-0000-000000000001';

  if active_version_id is distinct from published_id then
    raise exception 'ACTIVE_CONFIGURATION_POINTER_INVALID';
  end if;

  begin
    update app.service_steps
       set duration_minutes = 60
     where id = 'da700000-0000-0000-0000-000000000001';
    raise exception 'PUBLISHED_DRAFT_CHILD_WAS_MUTABLE';
  exception
    when object_not_in_prerequisite_state then null;
  end;

  begin
    update app.configuration_versions
       set snapshot = '{}'::jsonb
     where id = published_id;
    raise exception 'PUBLISHED_SNAPSHOT_WAS_MUTABLE';
  exception
    when insufficient_privilege or object_not_in_prerequisite_state then null;
  end;
end;
$;

reset role;
rollback;

select 'PUBLISH_SMOKE_OK' as result;
