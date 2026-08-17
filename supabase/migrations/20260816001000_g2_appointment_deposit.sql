begin;

-- Políticas por serviço e versão publicada. A origem de verdade para um
-- agendamento é sempre a versão indicada pelo hold; o depósito criado abaixo
-- guarda uma cópia imutável desta política.
create type app.deposit_policy_kind as enum ('NONE', 'FIXED_CENTS', 'PERCENT');
create type app.deposit_status as enum ('NOT_REQUIRED', 'PENDING', 'CONFIRMED', 'EXPIRED', 'WAIVED', 'CANCELLED');

create table app.service_deposit_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_version_id uuid not null,
  service_id uuid not null,
  policy_kind app.deposit_policy_kind not null default 'NONE',
  policy_value integer not null default 0,
  due_within_minutes integer,
  currency char(3) not null default 'BRL' check (currency = 'BRL'),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint service_deposit_policies_tenant_version_fk
    foreign key (tenant_id, configuration_version_id)
    references app.configuration_versions(tenant_id, id) on delete restrict,
  constraint service_deposit_policies_policy_valid check (
    (policy_kind = 'NONE' and policy_value = 0 and due_within_minutes is null)
    or (policy_kind = 'FIXED_CENTS' and policy_value > 0 and due_within_minutes > 0)
    or (policy_kind = 'PERCENT' and policy_value between 1 and 100 and due_within_minutes > 0)
  ),
  unique (tenant_id, configuration_version_id, service_id)
);

create table app.appointment_deposits (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  appointment_id uuid not null,
  policy_kind app.deposit_policy_kind not null,
  policy_value integer not null,
  policy_due_within_minutes integer,
  amount_cents integer not null check (amount_cents >= 0),
  currency char(3) not null check (currency = 'BRL'),
  due_at timestamptz,
  status app.deposit_status not null,
  confirmed_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint appointment_deposits_tenant_appointment_fk
    foreign key (tenant_id, appointment_id)
    references app.appointments(tenant_id, id) on delete restrict,
  constraint appointment_deposits_one_per_appointment unique (tenant_id, appointment_id),
  constraint appointment_deposits_snapshot_valid check (
    (policy_kind = 'NONE' and policy_value = 0 and policy_due_within_minutes is null
      and amount_cents = 0 and due_at is null and status = 'NOT_REQUIRED')
    or (policy_kind = 'FIXED_CENTS' and policy_value > 0 and policy_due_within_minutes > 0
      and amount_cents > 0 and due_at is not null and status <> 'NOT_REQUIRED')
    or (policy_kind = 'PERCENT' and policy_value between 1 and 100 and policy_due_within_minutes > 0
      and amount_cents > 0 and due_at is not null and status <> 'NOT_REQUIRED')
  ),
  constraint appointment_deposits_confirmation_valid check (
    (status = 'CONFIRMED' and confirmed_at is not null)
    or (status <> 'CONFIRMED')
  )
);

create table app.appointment_deposit_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  appointment_deposit_id uuid not null,
  appointment_id uuid not null,
  event_source text not null check (event_source in ('MANUAL_VERIFIED', 'SYSTEM_CANCELLATION')),
  external_event_ref text not null check (length(trim(external_event_ref)) between 8 and 200),
  resulting_status app.deposit_status not null,
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  actor_type text not null check (actor_type in ('USER', 'SYSTEM', 'WORKER')),
  actor_id uuid,
  metadata_minimized jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint appointment_deposit_events_tenant_deposit_fk
    foreign key (tenant_id, appointment_deposit_id)
    references app.appointment_deposits(tenant_id, id) on delete restrict,
  constraint appointment_deposit_events_tenant_appointment_fk
    foreign key (tenant_id, appointment_id)
    references app.appointments(tenant_id, id) on delete restrict,
  constraint appointment_deposit_events_idempotency
    unique (tenant_id, event_source, external_event_ref)
);

create index appointment_deposits_tenant_status_due_at_idx
  on app.appointment_deposits (tenant_id, status, due_at)
  where status = 'PENDING';
create index appointment_deposit_events_tenant_appointment_idx
  on app.appointment_deposit_events (tenant_id, appointment_id, occurred_at);

-- O snapshot financeiro não pode ser reescrito após a conversão do hold.
create or replace function private.prevent_appointment_deposit_snapshot_rewrite()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.tenant_id is distinct from old.tenant_id
    or new.appointment_id is distinct from old.appointment_id
    or new.policy_kind is distinct from old.policy_kind
    or new.policy_value is distinct from old.policy_value
    or new.policy_due_within_minutes is distinct from old.policy_due_within_minutes
    or new.amount_cents is distinct from old.amount_cents
    or new.currency is distinct from old.currency
    or new.due_at is distinct from old.due_at then
    raise exception using errcode = '55000', message = 'DEPOSIT_SNAPSHOT_IMMUTABLE';
  end if;

  new.updated_at := statement_timestamp();
  return new;
end;
$function$;

create trigger appointment_deposits_preserve_snapshot
before update on app.appointment_deposits
for each row execute function private.prevent_appointment_deposit_snapshot_rewrite();

create or replace function private.prevent_appointment_deposit_event_mutation()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  raise exception using errcode = '55000', message = 'DEPOSIT_EVENT_IMMUTABLE';
end;
$function$;

create trigger appointment_deposit_events_immutable
before update or delete on app.appointment_deposit_events
for each row execute function private.prevent_appointment_deposit_event_mutation();

alter table app.service_deposit_policies enable row level security;
alter table app.service_deposit_policies force row level security;
alter table app.appointment_deposits enable row level security;
alter table app.appointment_deposits force row level security;
alter table app.appointment_deposit_events enable row level security;
alter table app.appointment_deposit_events force row level security;

create policy service_deposit_policies_service_role
  on app.service_deposit_policies for all to service_role using (true) with check (true);
create policy appointment_deposits_service_role
  on app.appointment_deposits for all to service_role using (true) with check (true);
create policy appointment_deposit_events_service_role
  on app.appointment_deposit_events for all to service_role using (true) with check (true);

revoke all on table app.service_deposit_policies from public, anon, authenticated;
revoke all on table app.appointment_deposits from public, anon, authenticated;
revoke all on table app.appointment_deposit_events from public, anon, authenticated;
grant select, insert, update, delete on table app.service_deposit_policies to service_role;
grant select, insert, update, delete on table app.appointment_deposits to service_role;
grant select, insert, update, delete on table app.appointment_deposit_events to service_role;

-- A conversão mantém o contrato anterior e adiciona a projeção do sinal. O
-- preço é extraído da configuração publicada indicada pelo hold, nunca do draft
-- atual; portanto edições posteriores não mudam o cálculo já aplicado.
create or replace function public.schedule_confirm_hold(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_hold_id uuid,
  target_correlation_id text,
  target_customer_label text default null,
  target_channel_connection_id uuid default null,
  target_external_contact_ref text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  hold_record app.schedule_holds%rowtype;
  existing_appointment app.appointments%rowtype;
  existing_deposit app.appointment_deposits%rowtype;
  policy_record app.service_deposit_policies%rowtype;
  new_appointment_id uuid;
  new_deposit_id uuid;
  service_price_cents integer;
  service_currency char(3);
  deposit_amount_cents integer := 0;
  deposit_due_at timestamptz;
  deposit_status app.deposit_status := 'NOT_REQUIRED';
  appointment_status app.appointment_status := 'CONFIRMED';
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select h.* into hold_record
    from app.schedule_holds h
   where h.id = target_hold_id and h.tenant_id = target_tenant_id
   for update;

  if hold_record.id is null then
    raise exception using errcode = '42501', message = 'HOLD_NOT_ACCESSIBLE';
  end if;

  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  if hold_record.status = 'CONVERTED' then
    select a.* into existing_appointment
      from app.appointments a
     where a.source_hold_id = hold_record.id;
    select d.* into existing_deposit
      from app.appointment_deposits d
     where d.tenant_id = hold_record.tenant_id and d.appointment_id = existing_appointment.id;

    return jsonb_build_object(
      'appointmentId', existing_appointment.id,
      'status', existing_appointment.status,
      'unitId', existing_appointment.unit_id,
      'serviceId', existing_appointment.service_id,
      'startsAt', existing_appointment.starts_at,
      'endsAt', existing_appointment.ends_at,
      'deposit', case when existing_deposit.id is null then null else jsonb_build_object(
        'depositId', existing_deposit.id,
        'status', existing_deposit.status,
        'amountCents', existing_deposit.amount_cents,
        'currency', existing_deposit.currency,
        'dueAt', existing_deposit.due_at
      ) end
    );
  end if;

  if hold_record.status <> 'ACTIVE' then
    raise exception using errcode = '55000', message = 'HOLD_NOT_ACTIVE';
  end if;

  if hold_record.expires_at < statement_timestamp() then
    update app.schedule_holds
       set status = 'EXPIRED', updated_at = statement_timestamp()
     where id = hold_record.id;
    update app.member_occupancies
       set status = 'EXPIRED', updated_at = statement_timestamp()
     where tenant_id = hold_record.tenant_id and source_type = 'HOLD'
       and source_id = hold_record.id and status = 'ACTIVE';
    update app.resource_occupancies
       set status = 'EXPIRED', updated_at = statement_timestamp()
     where tenant_id = hold_record.tenant_id and source_type = 'HOLD'
       and source_id = hold_record.id and status = 'ACTIVE';
    raise exception using errcode = '55000', message = 'HOLD_EXPIRED';
  end if;

  select p.* into policy_record
    from app.service_deposit_policies p
   where p.tenant_id = hold_record.tenant_id
     and p.configuration_version_id = hold_record.configuration_version_id
     and p.service_id = hold_record.service_id;

  if policy_record.id is null then
    policy_record.policy_kind := 'NONE';
    policy_record.policy_value := 0;
    policy_record.due_within_minutes := null;
    policy_record.currency := 'BRL';
  end if;

  if policy_record.policy_kind <> 'NONE' then
    select
      coalesce(
        case when hold_record.variation_id is null then null else (
          select variation ->> 'price_minor'
            from jsonb_array_elements(coalesce(service_snapshot -> 'variations', '[]'::jsonb)) variation
           where variation ->> 'id' = hold_record.variation_id::text
           limit 1
        ) end,
        service_snapshot ->> 'base_price_minor'
      )::integer,
      coalesce(service_snapshot ->> 'currency', 'BRL')::char(3)
      into service_price_cents, service_currency
      from app.configuration_versions version_record
      cross join lateral jsonb_array_elements(coalesce(version_record.snapshot -> 'services', '[]'::jsonb)) service_snapshot
     where version_record.id = hold_record.configuration_version_id
       and version_record.tenant_id = hold_record.tenant_id
       and service_snapshot ->> 'id' = hold_record.service_id::text;

    if service_price_cents is null or service_price_cents < 0 or service_currency <> 'BRL' then
      raise exception using errcode = '22023', message = 'INVALID_SERVICE_PRICE_FOR_DEPOSIT';
    end if;

    deposit_amount_cents := case policy_record.policy_kind
      when 'FIXED_CENTS' then policy_record.policy_value
      when 'PERCENT' then round((service_price_cents::numeric * policy_record.policy_value::numeric) / 100)::integer
      else 0
    end;

    if deposit_amount_cents <= 0 or deposit_amount_cents > service_price_cents then
      raise exception using errcode = '22023', message = 'INVALID_DEPOSIT_AMOUNT';
    end if;

    deposit_due_at := statement_timestamp() + make_interval(mins => policy_record.due_within_minutes);
    deposit_status := 'PENDING';
    appointment_status := 'PENDING_SIGNAL';
  end if;

  insert into app.appointments (
    tenant_id, unit_id, configuration_version_id, source_hold_id, service_id, variation_id,
    starts_at, ends_at, status, plan, customer_label, channel_connection_id, external_contact_ref,
    correlation_id, created_by
  ) values (
    hold_record.tenant_id, hold_record.unit_id, hold_record.configuration_version_id, hold_record.id,
    hold_record.service_id, hold_record.variation_id, hold_record.starts_at, hold_record.ends_at,
    appointment_status, hold_record.plan, target_customer_label, target_channel_connection_id, target_external_contact_ref,
    target_correlation_id, null
  ) returning id into new_appointment_id;

  insert into app.appointment_deposits (
    tenant_id, appointment_id, policy_kind, policy_value, policy_due_within_minutes,
    amount_cents, currency, due_at, status
  ) values (
    hold_record.tenant_id, new_appointment_id, policy_record.policy_kind, policy_record.policy_value,
    policy_record.due_within_minutes, deposit_amount_cents, policy_record.currency,
    deposit_due_at, deposit_status
  ) returning id into new_deposit_id;

  update app.member_occupancies
     set source_type = 'APPOINTMENT', source_id = new_appointment_id, expires_at = null, updated_at = statement_timestamp()
   where tenant_id = hold_record.tenant_id and source_type = 'HOLD'
     and source_id = hold_record.id and status = 'ACTIVE';
  update app.resource_occupancies
     set source_type = 'APPOINTMENT', source_id = new_appointment_id, expires_at = null, updated_at = statement_timestamp()
   where tenant_id = hold_record.tenant_id and source_type = 'HOLD'
     and source_id = hold_record.id and status = 'ACTIVE';
  update app.schedule_holds
     set status = 'CONVERTED', updated_at = statement_timestamp()
   where id = hold_record.id;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    hold_record.tenant_id, 'USER', null, 'SCHEDULE_HOLD_CONFIRMED', 'appointment', new_appointment_id,
    hold_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object(
      'holdId', hold_record.id,
      'depositStatus', deposit_status,
      'depositAmountCents', deposit_amount_cents,
      'actorEmail', lower(trim(target_email))
    )
  );

  return jsonb_build_object(
    'appointmentId', new_appointment_id,
    'status', appointment_status,
    'unitId', hold_record.unit_id,
    'serviceId', hold_record.service_id,
    'startsAt', hold_record.starts_at,
    'endsAt', hold_record.ends_at,
    'deposit', jsonb_build_object(
      'depositId', new_deposit_id,
      'status', deposit_status,
      'amountCents', deposit_amount_cents,
      'currency', policy_record.currency,
      'dueAt', deposit_due_at
    )
  );
end;
$function$;

-- Somente OWNER ou ADMIN pode registrar que verificou o sinal manualmente. A
-- referência opaca é obrigatória e a chave única evita duplicação por retry.
create or replace function public.schedule_register_deposit_confirmation(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_appointment_id uuid,
  target_external_event_ref text,
  target_correlation_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  appointment_record app.appointments%rowtype;
  deposit_record app.appointment_deposits%rowtype;
  existing_event app.appointment_deposit_events%rowtype;
  new_event_id uuid;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;
  if target_external_event_ref is null or length(trim(target_external_event_ref)) not between 8 and 200 then
    raise exception using errcode = '22023', message = 'INVALID_DEPOSIT_EVENT_REFERENCE';
  end if;

  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  select a.* into appointment_record
    from app.appointments a
   where a.id = target_appointment_id and a.tenant_id = target_tenant_id
   for update;
  if appointment_record.id is null then
    raise exception using errcode = '42501', message = 'APPOINTMENT_NOT_ACCESSIBLE';
  end if;

  select d.* into deposit_record
    from app.appointment_deposits d
   where d.tenant_id = target_tenant_id and d.appointment_id = appointment_record.id
   for update;
  if deposit_record.id is null then
    raise exception using errcode = '55000', message = 'APPOINTMENT_DEPOSIT_NOT_FOUND';
  end if;

  select e.* into existing_event
    from app.appointment_deposit_events e
   where e.tenant_id = target_tenant_id
     and e.event_source = 'MANUAL_VERIFIED'
     and e.external_event_ref = trim(target_external_event_ref);
  if existing_event.id is not null then
    if existing_event.appointment_id <> appointment_record.id then
      raise exception using errcode = '23505', message = 'DEPOSIT_EVENT_REFERENCE_REUSED';
    end if;
    return jsonb_build_object(
      'appointmentId', appointment_record.id,
      'appointmentStatus', appointment_record.status,
      'depositId', deposit_record.id,
      'depositStatus', deposit_record.status,
      'eventId', existing_event.id,
      'idempotent', true
    );
  end if;

  if appointment_record.status <> 'PENDING_SIGNAL' or deposit_record.status <> 'PENDING' then
    raise exception using errcode = '55000', message = 'DEPOSIT_NOT_CONFIRMABLE';
  end if;

  insert into app.appointment_deposit_events (
    tenant_id, appointment_deposit_id, appointment_id, event_source,
    external_event_ref, resulting_status, correlation_id, actor_type, actor_id,
    metadata_minimized
  ) values (
    target_tenant_id, deposit_record.id, appointment_record.id, 'MANUAL_VERIFIED',
    trim(target_external_event_ref), 'CONFIRMED', target_correlation_id, 'USER', null,
    jsonb_build_object('actorEmail', lower(trim(target_email)))
  ) on conflict (tenant_id, event_source, external_event_ref) do nothing
    returning id into new_event_id;

  if new_event_id is null then
    select e.* into existing_event
      from app.appointment_deposit_events e
     where e.tenant_id = target_tenant_id
       and e.event_source = 'MANUAL_VERIFIED'
       and e.external_event_ref = trim(target_external_event_ref);
    if existing_event.appointment_id <> appointment_record.id then
      raise exception using errcode = '23505', message = 'DEPOSIT_EVENT_REFERENCE_REUSED';
    end if;
    return jsonb_build_object(
      'appointmentId', appointment_record.id,
      'appointmentStatus', appointment_record.status,
      'depositId', deposit_record.id,
      'depositStatus', deposit_record.status,
      'eventId', existing_event.id,
      'idempotent', true
    );
  end if;

  update app.appointment_deposits
     set status = 'CONFIRMED', confirmed_at = statement_timestamp()
   where id = deposit_record.id;
  update app.appointments
     set status = 'CONFIRMED', updated_at = statement_timestamp()
   where id = appointment_record.id;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    target_tenant_id, 'USER', null, 'APPOINTMENT_DEPOSIT_CONFIRMED', 'appointment_deposit', deposit_record.id,
    appointment_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object(
      'appointmentId', appointment_record.id,
      'eventSource', 'MANUAL_VERIFIED',
      'externalEventRef', trim(target_external_event_ref),
      'actorEmail', lower(trim(target_email))
    )
  );

  return jsonb_build_object(
    'appointmentId', appointment_record.id,
    'appointmentStatus', 'CONFIRMED',
    'depositId', deposit_record.id,
    'depositStatus', 'CONFIRMED',
    'eventId', new_event_id,
    'idempotent', false
  );
end;
$function$;

-- Preserva o cancelamento de teste de mechas existente e acrescenta o
-- cancelamento do sinal pendente, sem afirmar ou processar estorno.
create or replace function public.schedule_cancel_appointment(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_appointment_id uuid,
  target_correlation_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  appointment_record app.appointments%rowtype;
  deposit_record app.appointment_deposits%rowtype;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select a.* into appointment_record
    from app.appointments a
   where a.id = target_appointment_id and a.tenant_id = target_tenant_id
   for update;
  if appointment_record.id is null then
    raise exception using errcode = '42501', message = 'APPOINTMENT_NOT_ACCESSIBLE';
  end if;

  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  if appointment_record.status = 'CANCELLED' then
    return;
  end if;
  if appointment_record.status not in ('CONFIRMED', 'PENDING_SIGNAL') then
    raise exception using errcode = '55000', message = 'APPOINTMENT_NOT_CANCELLABLE';
  end if;

  select d.* into deposit_record
    from app.appointment_deposits d
   where d.tenant_id = target_tenant_id and d.appointment_id = appointment_record.id
   for update;

  update app.appointments
     set status = 'CANCELLED', updated_at = statement_timestamp()
   where id = appointment_record.id;
  update app.member_occupancies
     set status = 'CANCELLED', updated_at = statement_timestamp()
   where tenant_id = appointment_record.tenant_id and source_type = 'APPOINTMENT'
     and source_id = appointment_record.id and status = 'ACTIVE';
  update app.resource_occupancies
     set status = 'CANCELLED', updated_at = statement_timestamp()
   where tenant_id = appointment_record.tenant_id and source_type = 'APPOINTMENT'
     and source_id = appointment_record.id and status = 'ACTIVE';
  update app.strand_test_bookings
     set status = 'CANCELLED', updated_at = statement_timestamp()
   where tenant_id = appointment_record.tenant_id
     and main_appointment_id = appointment_record.id
     and status in ('SCHEDULED', 'COMPLETED');

  if deposit_record.id is not null and deposit_record.status = 'PENDING' then
    update app.appointment_deposits
       set status = 'CANCELLED'
     where id = deposit_record.id;
    insert into app.appointment_deposit_events (
      tenant_id, appointment_deposit_id, appointment_id, event_source,
      external_event_ref, resulting_status, correlation_id, actor_type, actor_id,
      metadata_minimized
    ) values (
      appointment_record.tenant_id, deposit_record.id, appointment_record.id, 'SYSTEM_CANCELLATION',
      appointment_record.id::text || ':' || target_correlation_id, 'CANCELLED', target_correlation_id,
      'USER', null, jsonb_build_object('actorEmail', lower(trim(target_email)))
    ) on conflict (tenant_id, event_source, external_event_ref) do nothing;
  end if;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    appointment_record.tenant_id, 'USER', null, 'APPOINTMENT_CANCELLED', 'appointment', appointment_record.id,
    appointment_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object(
      'depositCancelled', coalesce(deposit_record.status = 'PENDING', false),
      'actorEmail', lower(trim(target_email))
    )
  );
end;
$function$;

revoke all on function public.schedule_confirm_hold(text, text, uuid, uuid, text, text, uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.schedule_register_deposit_confirmation(text, text, uuid, uuid, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.schedule_cancel_appointment(text, text, uuid, uuid, text)
  from public, anon, authenticated, service_role;

grant execute on function public.schedule_confirm_hold(text, text, uuid, uuid, text, text, uuid, text) to service_role;
grant execute on function public.schedule_register_deposit_confirmation(text, text, uuid, uuid, text, text) to service_role;
grant execute on function public.schedule_cancel_appointment(text, text, uuid, uuid, text) to service_role;

commit;
