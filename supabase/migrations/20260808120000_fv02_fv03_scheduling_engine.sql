begin;

-- FV-02/FV-03 — motor de agenda: ledger unificado de ocupações, holds e
-- agendamentos confirmados. Segue docs/canonical/arquitetura-tecnica-piloto-v1.md
-- seção 14 (ledger unificado) e docs/canonical/backlog-tecnico-piloto-v1.md
-- BT-200 a BT-206.
--
-- Escopo real desta migration (nada além disto foi implementado ainda):
--   - app.schedule_holds        (BT-200: expiração + idempotência)
--   - app.member_occupancies    (BT-201: ledger, exclusion constraint GiST)
--   - app.resource_occupancies  (BT-201: idem, com vagas físicas via slot_index)
--   - app.appointments          (BT-202: conversão transacional hold -> agendamento)
--   - api.create_schedule_hold / api.confirm_schedule_hold /
--     api.cancel_schedule_hold / api.cancel_appointment
--   - private.expire_stale_holds (expiração "preguiçosa", lida a cada escrita —
--     BT-203 pede também um worker periódico; esse worker NÃO foi construído
--     aqui, então um hold expirado só é varrido na próxima escrita/confirmação
--     na mesma unidade, não instantaneamente)
--
-- A prova de concorrência (BT-205, "cem confirmações concorrentes") depende da
-- exclusion constraint abaixo, não de lock de aplicação — ela é testada por um
-- script separado (não SQL) depois desta migration existir.

create extension if not exists btree_gist with schema extensions;

create type app.occupancy_source_type as enum ('HOLD', 'APPOINTMENT', 'EXTERNAL_BLOCK');
create type app.occupancy_status as enum ('ACTIVE', 'RELEASED', 'EXPIRED', 'CANCELLED');
create type app.hold_status as enum ('ACTIVE', 'CONVERTED', 'EXPIRED', 'CANCELLED');
create type app.appointment_status as enum ('CONFIRMED', 'CANCELLED', 'COMPLETED', 'NO_SHOW');

-- ---------------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------------

create table app.schedule_holds (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  configuration_version_id uuid not null,
  service_id uuid not null,
  variation_id uuid,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status app.hold_status not null default 'ACTIVE',
  -- Plano completo devolvido pelo motor (etapas, membros e recursos
  -- escolhidos), guardado para reconstrução, auditoria e para a conversão em
  -- agendamento não precisar rechamar o motor.
  plan jsonb not null,
  idempotency_key text not null check (length(idempotency_key) between 8 and 200),
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  expires_at timestamptz not null,
  created_by uuid references app.profiles(id) on delete set null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (starts_at < ends_at),
  unique (tenant_id, id),
  unique (tenant_id, idempotency_key),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete restrict,
  foreign key (tenant_id, configuration_version_id)
    references app.configuration_versions(tenant_id, id) on delete restrict
);

create table app.appointments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  configuration_version_id uuid not null,
  source_hold_id uuid,
  service_id uuid not null,
  variation_id uuid,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status app.appointment_status not null default 'CONFIRMED',
  plan jsonb not null,
  -- Sem CRM ainda (módulo Clientes não existe): identificação mínima e opaca.
  customer_label text check (customer_label is null or length(trim(customer_label)) between 1 and 160),
  channel_connection_id uuid,
  external_contact_ref text check (external_contact_ref is null or length(trim(external_contact_ref)) between 1 and 200),
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  created_by uuid references app.profiles(id) on delete set null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (starts_at < ends_at),
  unique (tenant_id, id),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete restrict,
  foreign key (tenant_id, configuration_version_id)
    references app.configuration_versions(tenant_id, id) on delete restrict,
  foreign key (tenant_id, source_hold_id)
    references app.schedule_holds(tenant_id, id) on delete set null
);

create table app.member_occupancies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  member_id uuid not null,
  source_type app.occupancy_source_type not null,
  source_id uuid not null,
  time_range tstzrange not null,
  status app.occupancy_status not null default 'ACTIVE',
  expires_at timestamptz,
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (source_type = 'HOLD' or expires_at is null),
  check (lower_inc(time_range) and not upper_inc(time_range) and not isempty(time_range)),
  unique (tenant_id, id),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete restrict
);

create table app.resource_occupancies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  resource_id uuid not null,
  -- Vaga física específica dentro da capacidade do recurso (1..capacity).
  -- É isso que permite capacidade > 1 sem perder a proteção da exclusion
  -- constraint: cada vaga só pode estar ocupada por um intervalo por vez.
  slot_index integer not null check (slot_index > 0),
  source_type app.occupancy_source_type not null,
  source_id uuid not null,
  time_range tstzrange not null,
  status app.occupancy_status not null default 'ACTIVE',
  expires_at timestamptz,
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (source_type = 'HOLD' or expires_at is null),
  check (lower_inc(time_range) and not upper_inc(time_range) and not isempty(time_range)),
  unique (tenant_id, id),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete restrict
);

-- ---------------------------------------------------------------------------
-- Proteção final contra dupla reserva: exclusion constraints GiST.
-- O predicado usa `status`, não `now()` — hold expirado só some da constraint
-- quando alguém (escrita seguinte) muda o status para EXPIRED.
-- ---------------------------------------------------------------------------

alter table app.member_occupancies
  add constraint member_occupancies_no_overlap
  exclude using gist (
    tenant_id with =,
    member_id with =,
    time_range with &&
  )
  where (status = 'ACTIVE');

alter table app.resource_occupancies
  add constraint resource_occupancies_no_overlap
  exclude using gist (
    tenant_id with =,
    resource_id with =,
    slot_index with =,
    time_range with &&
  )
  where (status = 'ACTIVE');

create index schedule_holds_unit_status_idx on app.schedule_holds (tenant_id, unit_id, status);
create index schedule_holds_expiry_idx on app.schedule_holds (status, expires_at) where status = 'ACTIVE';
create index appointments_unit_starts_idx on app.appointments (tenant_id, unit_id, starts_at);
create index appointments_source_hold_idx on app.appointments (tenant_id, source_hold_id);
create index member_occupancies_active_idx on app.member_occupancies (tenant_id, member_id) where status = 'ACTIVE';
create index member_occupancies_source_idx on app.member_occupancies (tenant_id, source_type, source_id);
create index resource_occupancies_active_idx on app.resource_occupancies (tenant_id, resource_id) where status = 'ACTIVE';
create index resource_occupancies_source_idx on app.resource_occupancies (tenant_id, source_type, source_id);

-- ---------------------------------------------------------------------------
-- RLS: leitura para membros do tenant; nenhuma escrita direta de cliente.
-- Toda mutação passa pelas funções api.* (SECURITY DEFINER) abaixo, que
-- validam identidade/tenant explicitamente no corpo — igual ao padrão já
-- usado em api.publish_configuration.
-- ---------------------------------------------------------------------------

alter table app.schedule_holds enable row level security;
alter table app.appointments enable row level security;
alter table app.member_occupancies enable row level security;
alter table app.resource_occupancies enable row level security;

create policy schedule_holds_select_member on app.schedule_holds
  for select to authenticated using (private.has_tenant_role(tenant_id));
create policy appointments_select_member on app.appointments
  for select to authenticated using (private.has_tenant_role(tenant_id));
create policy member_occupancies_select_member on app.member_occupancies
  for select to authenticated using (private.has_tenant_role(tenant_id));
create policy resource_occupancies_select_member on app.resource_occupancies
  for select to authenticated using (private.has_tenant_role(tenant_id));

grant select on table app.schedule_holds to authenticated;
grant select on table app.appointments to authenticated;
grant select on table app.member_occupancies to authenticated;
grant select on table app.resource_occupancies to authenticated;

grant select, insert, update, delete on table app.schedule_holds to service_role;
grant select, insert, update, delete on table app.appointments to service_role;
grant select, insert, update, delete on table app.member_occupancies to service_role;
grant select, insert, update, delete on table app.resource_occupancies to service_role;

create trigger schedule_holds_touch_updated_at
  before update on app.schedule_holds
  for each row execute function private.touch_updated_at();
create trigger appointments_touch_updated_at
  before update on app.appointments
  for each row execute function private.touch_updated_at();
create trigger member_occupancies_touch_updated_at
  before update on app.member_occupancies
  for each row execute function private.touch_updated_at();
create trigger resource_occupancies_touch_updated_at
  before update on app.resource_occupancies
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- private.expire_stale_holds — varredura preguiçosa (lazy), chamada no início
-- de create/confirm para que um hold vencido nunca bloqueie um novo pedido.
-- ---------------------------------------------------------------------------

create or replace function private.expire_stale_holds(target_tenant_id uuid, target_unit_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_hold record;
begin
  for expired_hold in
    select id from app.schedule_holds
     where tenant_id = target_tenant_id
       and unit_id = target_unit_id
       and status = 'ACTIVE'
       and expires_at < statement_timestamp()
     for update skip locked
  loop
    update app.schedule_holds
       set status = 'EXPIRED', updated_at = statement_timestamp()
     where id = expired_hold.id;

    update app.member_occupancies
       set status = 'EXPIRED', updated_at = statement_timestamp()
     where tenant_id = target_tenant_id
       and source_type = 'HOLD'
       and source_id = expired_hold.id
       and status = 'ACTIVE';

    update app.resource_occupancies
       set status = 'EXPIRED', updated_at = statement_timestamp()
     where tenant_id = target_tenant_id
       and source_type = 'HOLD'
       and source_id = expired_hold.id
       and status = 'ACTIVE';
  end loop;
end;
$$;

revoke all on function private.expire_stale_holds(uuid, uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- api.create_schedule_hold — cria o hold e todas as ocupações do plano numa
-- única transação. `target_plan` é o plano já resolvido pelo motor
-- (@beauty/scheduling-engine), no formato:
--   { "steps": [ { "stepId", "startMs", "endMs", "memberId"?,
--       "resourceAssignments": [ { "resourceId", "quantity", "capacity" } ] } ] }
-- `capacity` vem embutido pelo chamador (a partir do snapshot publicado, não
-- de app.resources ao vivo) para nunca depender de um rascunho mutável.
-- ---------------------------------------------------------------------------

create or replace function api.create_schedule_hold(
  target_unit_id uuid,
  target_configuration_version_id uuid,
  target_service_id uuid,
  target_variation_id uuid,
  target_starts_at timestamptz,
  target_ends_at timestamptz,
  target_plan jsonb,
  target_idempotency_key text,
  target_correlation_id text,
  hold_ttl_seconds integer default 600
)
returns table (
  hold_id uuid,
  hold_status app.hold_status,
  hold_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  tenant uuid;
  existing app.schedule_holds%rowtype;
  new_hold_id uuid;
  new_expires_at timestamptz;
  step jsonb;
  resource_req jsonb;
  step_start timestamptz;
  step_end timestamptz;
  needed integer;
  capacity_value integer;
  claimed integer;
  chosen_slot integer;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;
  if target_idempotency_key is null or length(target_idempotency_key) not between 8 and 200 then
    raise exception using errcode = '22023', message = 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if target_starts_at >= target_ends_at then
    raise exception using errcode = '22023', message = 'INVALID_TIME_RANGE';
  end if;
  if hold_ttl_seconds is null or hold_ttl_seconds <= 0 or hold_ttl_seconds > 3600 then
    raise exception using errcode = '22023', message = 'INVALID_HOLD_TTL';
  end if;

  select cv.tenant_id into tenant
    from app.configuration_versions cv
   where cv.id = target_configuration_version_id;

  if tenant is null or not private.has_tenant_role(tenant) then
    raise exception using errcode = '42501', message = 'CONFIGURATION_NOT_ACCESSIBLE';
  end if;

  -- Idempotência (BT-200): repetição com a mesma chave retorna o mesmo efeito lógico.
  select h.* into existing
    from app.schedule_holds h
   where h.tenant_id = tenant and h.idempotency_key = target_idempotency_key;

  if existing.id is not null then
    return query select existing.id, existing.status, existing.expires_at;
    return;
  end if;

  perform private.expire_stale_holds(tenant, target_unit_id);

  new_expires_at := statement_timestamp() + make_interval(secs => hold_ttl_seconds);

  insert into app.schedule_holds (
    tenant_id, unit_id, configuration_version_id, service_id, variation_id,
    starts_at, ends_at, status, plan, idempotency_key, correlation_id, expires_at, created_by
  ) values (
    tenant, target_unit_id, target_configuration_version_id, target_service_id, target_variation_id,
    target_starts_at, target_ends_at, 'ACTIVE', target_plan, target_idempotency_key, target_correlation_id,
    new_expires_at, auth.uid()
  )
  returning id into new_hold_id;

  for step in select * from jsonb_array_elements(target_plan -> 'steps')
  loop
    step_start := to_timestamp((step ->> 'startMs')::numeric / 1000.0);
    step_end := to_timestamp((step ->> 'endMs')::numeric / 1000.0);

    if (step ->> 'memberId') is not null then
      begin
        insert into app.member_occupancies (
          tenant_id, unit_id, member_id, source_type, source_id, time_range, status, expires_at, correlation_id
        ) values (
          tenant, target_unit_id, (step ->> 'memberId')::uuid, 'HOLD', new_hold_id,
          tstzrange(step_start, step_end, '[)'), 'ACTIVE', new_expires_at, target_correlation_id
        );
      exception when exclusion_violation then
        raise exception using errcode = '40001', message = 'MEMBER_OCCUPIED';
      end;
    end if;

    for resource_req in select * from jsonb_array_elements(coalesce(step -> 'resourceAssignments', '[]'::jsonb))
    loop
      needed := (resource_req ->> 'quantity')::integer;
      capacity_value := (resource_req ->> 'capacity')::integer;
      claimed := 0;

      if needed is null or needed <= 0 or capacity_value is null or capacity_value <= 0 then
        raise exception using errcode = '22023', message = 'INVALID_RESOURCE_ASSIGNMENT';
      end if;

      chosen_slot := 1;
      while chosen_slot <= capacity_value and claimed < needed loop
        begin
          insert into app.resource_occupancies (
            tenant_id, unit_id, resource_id, slot_index, source_type, source_id, time_range, status, expires_at, correlation_id
          ) values (
            tenant, target_unit_id, (resource_req ->> 'resourceId')::uuid, chosen_slot, 'HOLD', new_hold_id,
            tstzrange(step_start, step_end, '[)'), 'ACTIVE', new_expires_at, target_correlation_id
          );
          claimed := claimed + 1;
        exception when exclusion_violation then
          null; -- vaga ocupada, tenta a próxima
        end;
        chosen_slot := chosen_slot + 1;
      end loop;

      if claimed < needed then
        raise exception using errcode = '40001', message = 'RESOURCE_CAPACITY_EXCEEDED';
      end if;
    end loop;
  end loop;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    tenant, 'USER', auth.uid(), 'SCHEDULE_HOLD_CREATED', 'schedule_hold', new_hold_id,
    target_configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object('unitId', target_unit_id, 'serviceId', target_service_id)
  );

  return query select new_hold_id, 'ACTIVE'::app.hold_status, new_expires_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- api.confirm_schedule_hold — conversão transacional hold -> agendamento
-- (BT-202). Não existe janela de liberação: as MESMAS linhas de ocupação
-- mudam de HOLD para APPOINTMENT dentro da mesma transação.
-- ---------------------------------------------------------------------------

create or replace function api.confirm_schedule_hold(
  target_hold_id uuid,
  target_correlation_id text,
  target_customer_label text default null,
  target_channel_connection_id uuid default null,
  target_external_contact_ref text default null
)
returns table (
  appointment_id uuid,
  resulting_status app.appointment_status
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  hold_record app.schedule_holds%rowtype;
  existing_appointment_id uuid;
  existing_status app.appointment_status;
  new_appointment_id uuid;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select h.* into hold_record from app.schedule_holds h where h.id = target_hold_id for update;

  if hold_record.id is null or not private.has_tenant_role(hold_record.tenant_id) then
    raise exception using errcode = '42501', message = 'HOLD_NOT_ACCESSIBLE';
  end if;

  if hold_record.status = 'CONVERTED' then
    select a.id, a.status into existing_appointment_id, existing_status
      from app.appointments a where a.source_hold_id = hold_record.id;
    return query select existing_appointment_id, existing_status;
    return;
  end if;

  if hold_record.status <> 'ACTIVE' then
    raise exception using errcode = '55000', message = 'HOLD_NOT_ACTIVE';
  end if;

  if hold_record.expires_at < statement_timestamp() then
    update app.schedule_holds set status = 'EXPIRED', updated_at = statement_timestamp() where id = hold_record.id;
    update app.member_occupancies set status = 'EXPIRED', updated_at = statement_timestamp()
     where tenant_id = hold_record.tenant_id and source_type = 'HOLD' and source_id = hold_record.id and status = 'ACTIVE';
    update app.resource_occupancies set status = 'EXPIRED', updated_at = statement_timestamp()
     where tenant_id = hold_record.tenant_id and source_type = 'HOLD' and source_id = hold_record.id and status = 'ACTIVE';
    raise exception using errcode = '55000', message = 'HOLD_EXPIRED';
  end if;

  insert into app.appointments (
    tenant_id, unit_id, configuration_version_id, source_hold_id, service_id, variation_id,
    starts_at, ends_at, status, plan, customer_label, channel_connection_id, external_contact_ref,
    correlation_id, created_by
  ) values (
    hold_record.tenant_id, hold_record.unit_id, hold_record.configuration_version_id, hold_record.id,
    hold_record.service_id, hold_record.variation_id, hold_record.starts_at, hold_record.ends_at,
    'CONFIRMED', hold_record.plan, target_customer_label, target_channel_connection_id, target_external_contact_ref,
    target_correlation_id, auth.uid()
  )
  returning id into new_appointment_id;

  update app.member_occupancies
     set source_type = 'APPOINTMENT', source_id = new_appointment_id, expires_at = null, updated_at = statement_timestamp()
   where tenant_id = hold_record.tenant_id and source_type = 'HOLD' and source_id = hold_record.id and status = 'ACTIVE';

  update app.resource_occupancies
     set source_type = 'APPOINTMENT', source_id = new_appointment_id, expires_at = null, updated_at = statement_timestamp()
   where tenant_id = hold_record.tenant_id and source_type = 'HOLD' and source_id = hold_record.id and status = 'ACTIVE';

  update app.schedule_holds set status = 'CONVERTED', updated_at = statement_timestamp() where id = hold_record.id;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    hold_record.tenant_id, 'USER', auth.uid(), 'SCHEDULE_HOLD_CONFIRMED', 'appointment', new_appointment_id,
    hold_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object('holdId', hold_record.id)
  );

  return query select new_appointment_id, 'CONFIRMED'::app.appointment_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cancelamento (BT-204) — idempotente; libera as ocupações ativas.
-- ---------------------------------------------------------------------------

create or replace function api.cancel_schedule_hold(target_hold_id uuid, target_correlation_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  hold_record app.schedule_holds%rowtype;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select h.* into hold_record from app.schedule_holds h where h.id = target_hold_id for update;

  if hold_record.id is null or not private.has_tenant_role(hold_record.tenant_id) then
    raise exception using errcode = '42501', message = 'HOLD_NOT_ACCESSIBLE';
  end if;

  if hold_record.status = 'CANCELLED' then
    return;
  end if;

  if hold_record.status <> 'ACTIVE' then
    raise exception using errcode = '55000', message = 'HOLD_NOT_ACTIVE';
  end if;

  update app.schedule_holds set status = 'CANCELLED', updated_at = statement_timestamp() where id = hold_record.id;

  update app.member_occupancies set status = 'RELEASED', updated_at = statement_timestamp()
   where tenant_id = hold_record.tenant_id and source_type = 'HOLD' and source_id = hold_record.id and status = 'ACTIVE';
  update app.resource_occupancies set status = 'RELEASED', updated_at = statement_timestamp()
   where tenant_id = hold_record.tenant_id and source_type = 'HOLD' and source_id = hold_record.id and status = 'ACTIVE';

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    hold_record.tenant_id, 'USER', auth.uid(), 'SCHEDULE_HOLD_CANCELLED', 'schedule_hold', hold_record.id,
    hold_record.configuration_version_id, target_correlation_id, 'SUCCESS', '{}'::jsonb
  );
end;
$$;

create or replace function api.cancel_appointment(target_appointment_id uuid, target_correlation_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  appointment_record app.appointments%rowtype;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select a.* into appointment_record from app.appointments a where a.id = target_appointment_id for update;

  if appointment_record.id is null or not private.has_tenant_role(appointment_record.tenant_id) then
    raise exception using errcode = '42501', message = 'APPOINTMENT_NOT_ACCESSIBLE';
  end if;

  if appointment_record.status = 'CANCELLED' then
    return;
  end if;

  if appointment_record.status <> 'CONFIRMED' then
    raise exception using errcode = '55000', message = 'APPOINTMENT_NOT_CANCELLABLE';
  end if;

  update app.appointments set status = 'CANCELLED', updated_at = statement_timestamp() where id = appointment_record.id;

  update app.member_occupancies set status = 'CANCELLED', updated_at = statement_timestamp()
   where tenant_id = appointment_record.tenant_id and source_type = 'APPOINTMENT' and source_id = appointment_record.id and status = 'ACTIVE';
  update app.resource_occupancies set status = 'CANCELLED', updated_at = statement_timestamp()
   where tenant_id = appointment_record.tenant_id and source_type = 'APPOINTMENT' and source_id = appointment_record.id and status = 'ACTIVE';

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    appointment_record.tenant_id, 'USER', auth.uid(), 'APPOINTMENT_CANCELLED', 'appointment', appointment_record.id,
    appointment_record.configuration_version_id, target_correlation_id, 'SUCCESS', '{}'::jsonb
  );
end;
$$;

revoke all on function api.create_schedule_hold(uuid, uuid, uuid, uuid, timestamptz, timestamptz, jsonb, text, text, integer)
  from public, anon, authenticated, service_role;
revoke all on function api.confirm_schedule_hold(uuid, text, text, uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function api.cancel_schedule_hold(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function api.cancel_appointment(uuid, text)
  from public, anon, authenticated, service_role;

grant execute on function api.create_schedule_hold(uuid, uuid, uuid, uuid, timestamptz, timestamptz, jsonb, text, text, integer)
  to authenticated, service_role;
grant execute on function api.confirm_schedule_hold(uuid, text, text, uuid, text)
  to authenticated, service_role;
grant execute on function api.cancel_schedule_hold(uuid, text)
  to authenticated, service_role;
grant execute on function api.cancel_appointment(uuid, text)
  to authenticated, service_role;

commit;
