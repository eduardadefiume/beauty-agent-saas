begin;

insert into app.tenants (id, display_name, slug)
values (
  'e1000000-0000-0000-0000-000000000001',
  'G2 Expiration Integration',
  'g2-expiration-integration'
);

insert into app.units (id, tenant_id, name, timezone)
values (
  'e1100000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'G2 Expiration Unit',
  'America/Sao_Paulo'
);

insert into app.configuration_drafts (id, tenant_id, unit_id, final_message_template)
values (
  'e1200000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'e1100000-0000-0000-0000-000000000001',
  'Teste de expiração de sinal.'
);

insert into app.configuration_versions (
  id, tenant_id, unit_id, source_draft_id, version_number, snapshot, snapshot_hash
) values (
  'e1300000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'e1100000-0000-0000-0000-000000000001',
  'e1200000-0000-0000-0000-000000000001',
  1,
  '{}'::jsonb,
  repeat('e', 64)
);

insert into app.appointments (
  id, tenant_id, unit_id, configuration_version_id, service_id, starts_at, ends_at,
  status, plan, correlation_id
) values
  (
    'e1400000-0000-0000-0000-000000000001',
    'e1000000-0000-0000-0000-000000000001',
    'e1100000-0000-0000-0000-000000000001',
    'e1300000-0000-0000-0000-000000000001',
    'e1600000-0000-0000-0000-000000000001',
    statement_timestamp() + interval '2 days',
    statement_timestamp() + interval '2 days 1 hour',
    'PENDING_SIGNAL',
    '{}'::jsonb,
    'g2-expiration-test-001'
  ),
  (
    'e1400000-0000-0000-0000-000000000002',
    'e1000000-0000-0000-0000-000000000001',
    'e1100000-0000-0000-0000-000000000001',
    'e1300000-0000-0000-0000-000000000001',
    'e1600000-0000-0000-0000-000000000002',
    statement_timestamp() + interval '3 days',
    statement_timestamp() + interval '3 days 1 hour',
    'PENDING_SIGNAL',
    '{}'::jsonb,
    'g2-expiration-test-002'
  ),
  (
    'e1400000-0000-0000-0000-000000000003',
    'e1000000-0000-0000-0000-000000000001',
    'e1100000-0000-0000-0000-000000000001',
    'e1300000-0000-0000-0000-000000000001',
    'e1600000-0000-0000-0000-000000000003',
    statement_timestamp() + interval '4 days',
    statement_timestamp() + interval '4 days 1 hour',
    'CONFIRMED',
    '{}'::jsonb,
    'g2-expiration-test-003'
  );

insert into app.appointment_deposits (
  id, tenant_id, appointment_id, policy_kind, policy_value, policy_due_within_minutes,
  amount_cents, currency, due_at, status, confirmed_at
) values
  (
    'e1500000-0000-0000-0000-000000000001',
    'e1000000-0000-0000-0000-000000000001',
    'e1400000-0000-0000-0000-000000000001',
    'FIXED_CENTS', 5000, 30, 5000, 'BRL', statement_timestamp() - interval '1 minute', 'PENDING', null
  ),
  (
    'e1500000-0000-0000-0000-000000000002',
    'e1000000-0000-0000-0000-000000000001',
    'e1400000-0000-0000-0000-000000000002',
    'FIXED_CENTS', 5000, 30, 5000, 'BRL', statement_timestamp() + interval '1 hour', 'PENDING', null
  ),
  (
    'e1500000-0000-0000-0000-000000000003',
    'e1000000-0000-0000-0000-000000000001',
    'e1400000-0000-0000-0000-000000000003',
    'FIXED_CENTS', 5000, 30, 5000, 'BRL', statement_timestamp() - interval '1 minute', 'CONFIRMED', statement_timestamp()
  );

insert into app.member_occupancies (
  tenant_id, unit_id, member_id, source_type, source_id, time_range, status, correlation_id
) values (
  'e1000000-0000-0000-0000-000000000001',
  'e1100000-0000-0000-0000-000000000001',
  'e1700000-0000-0000-0000-000000000001',
  'APPOINTMENT',
  'e1400000-0000-0000-0000-000000000001',
  tstzrange(statement_timestamp() + interval '2 days', statement_timestamp() + interval '2 days 1 hour', '[)'),
  'ACTIVE',
  'g2-expiration-test-001'
);

insert into app.resource_occupancies (
  tenant_id, unit_id, resource_id, slot_index, source_type, source_id, time_range, status, correlation_id
) values (
  'e1000000-0000-0000-0000-000000000001',
  'e1100000-0000-0000-0000-000000000001',
  'e1800000-0000-0000-0000-000000000001',
  1,
  'APPOINTMENT',
  'e1400000-0000-0000-0000-000000000001',
  tstzrange(statement_timestamp() + interval '2 days', statement_timestamp() + interval '2 days 1 hour', '[)'),
  'ACTIVE',
  'g2-expiration-test-001'
);

do $$
declare
  first_processed integer;
  second_processed integer;
  event_count integer;
  audit_count integer;
  expired_status app.deposit_status;
  expired_appointment_status app.appointment_status;
  member_status app.occupancy_status;
  resource_status app.occupancy_status;
  future_status app.deposit_status;
  confirmed_status app.deposit_status;
  future_appointment_status app.appointment_status;
begin
  first_processed := public.schedule_expire_due_deposits('g2-expiration-run-001', 10);
  if first_processed <> 1 then
    raise exception 'EXPECTED_ONE_EXPIRED_DEPOSIT_GOT_%', first_processed;
  end if;

  second_processed := public.schedule_expire_due_deposits('g2-expiration-run-002', 10);
  if second_processed <> 0 then
    raise exception 'EXPIRATION_NOT_IDEMPOTENT_GOT_%', second_processed;
  end if;

  select d.status, a.status into expired_status, expired_appointment_status
    from app.appointment_deposits d
    join app.appointments a on a.tenant_id = d.tenant_id and a.id = d.appointment_id
   where d.id = 'e1500000-0000-0000-0000-000000000001';
  if expired_status <> 'EXPIRED' or expired_appointment_status <> 'CANCELLED' then
    raise exception 'EXPIRED_STATE_INVALID_%_%', expired_status, expired_appointment_status;
  end if;

  select status into member_status from app.member_occupancies
   where source_id = 'e1400000-0000-0000-0000-000000000001';
  select status into resource_status from app.resource_occupancies
   where source_id = 'e1400000-0000-0000-0000-000000000001';
  if member_status <> 'CANCELLED' or resource_status <> 'CANCELLED' then
    raise exception 'OCCUPANCIES_NOT_RELEASED_%_%', member_status, resource_status;
  end if;

  select count(*) into event_count from app.appointment_deposit_events
   where appointment_deposit_id = 'e1500000-0000-0000-0000-000000000001'
     and event_source = 'SYSTEM_EXPIRATION';
  if event_count <> 1 then
    raise exception 'EXPIRATION_EVENT_COUNT_INVALID_%', event_count;
  end if;

  select count(*) into audit_count from app.audit_logs
   where entity_id = 'e1400000-0000-0000-0000-000000000001'
     and action = 'APPOINTMENT_DEPOSIT_EXPIRED'
     and actor_type = 'WORKER';
  if audit_count <> 1 then
    raise exception 'EXPIRATION_AUDIT_COUNT_INVALID_%', audit_count;
  end if;

  select d.status, a.status into future_status, future_appointment_status
    from app.appointment_deposits d
    join app.appointments a on a.tenant_id = d.tenant_id and a.id = d.appointment_id
   where d.id = 'e1500000-0000-0000-0000-000000000002';
  if future_status <> 'PENDING' or future_appointment_status <> 'PENDING_SIGNAL' then
    raise exception 'FUTURE_DEPOSIT_WAS_MODIFIED_%_%', future_status, future_appointment_status;
  end if;

  select status into confirmed_status from app.appointment_deposits
   where id = 'e1500000-0000-0000-0000-000000000003';
  if confirmed_status <> 'CONFIRMED' then
    raise exception 'CONFIRMED_DEPOSIT_WAS_MODIFIED_%', confirmed_status;
  end if;

  if not has_function_privilege('service_role', 'public.schedule_expire_due_deposits(text,integer)', 'EXECUTE')
    or has_function_privilege('anon', 'public.schedule_expire_due_deposits(text,integer)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.schedule_expire_due_deposits(text,integer)', 'EXECUTE') then
    raise exception 'EXPIRATION_FUNCTION_GRANTS_INVALID';
  end if;

  if exists (
    select 1
      from pg_class table_catalog
      join pg_namespace schema_catalog on schema_catalog.oid = table_catalog.relnamespace
     where schema_catalog.nspname = 'app'
       and table_catalog.relname in ('appointment_deposits', 'appointment_deposit_events')
       and (not table_catalog.relrowsecurity or not table_catalog.relforcerowsecurity)
  ) then
    raise exception 'DEPOSIT_RLS_NOT_FORCED';
  end if;
end;
$$;

rollback;

select 'G2_DEPOSIT_EXPIRATION_INTEGRATION_OK' as result;
