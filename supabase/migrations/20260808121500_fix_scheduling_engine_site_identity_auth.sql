begin;

-- Correção: a migration anterior (fv02_fv03_scheduling_engine) autorizava as
-- RPCs via private.has_tenant_role(tenant_id)/auth.uid(), que depende de
-- app.tenant_memberships — tabela que hoje está VAZIA, porque o app real
-- (apps/web -> owner-console-api) nunca usou esse caminho. O mecanismo que
-- de fato está em produção é app.site_identities + private.require_site_tenant
-- (o mesmo usado por public.site_list_tenants/site_publish_configuration).
-- Sem esta correção, toda chamada às RPCs de hold/agendamento retornaria
-- 42501 para a própria Duda. Substitui as 4 funções api.* por equivalentes
-- public.schedule_* no mesmo formato de public.site_*.

drop function if exists api.cancel_appointment(uuid, text);
drop function if exists api.cancel_schedule_hold(uuid, text);
drop function if exists api.confirm_schedule_hold(uuid, text, text, uuid, text);
drop function if exists api.create_schedule_hold(uuid, uuid, uuid, uuid, timestamptz, timestamptz, jsonb, text, text, integer);

create or replace function public.schedule_list_occupancies(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);
  perform private.expire_stale_holds(target_tenant_id, target_unit_id);

  return jsonb_build_object(
    'memberOccupancies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', o.member_id,
        'startMs', floor(extract(epoch from lower(o.time_range)) * 1000),
        'endMs', floor(extract(epoch from upper(o.time_range)) * 1000)
      ))
        from app.member_occupancies o
       where o.tenant_id = target_tenant_id and o.unit_id = target_unit_id and o.status = 'ACTIVE'
    ), '[]'::jsonb),
    'resourceOccupancies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'resourceId', o.resource_id,
        'startMs', floor(extract(epoch from lower(o.time_range)) * 1000),
        'endMs', floor(extract(epoch from upper(o.time_range)) * 1000)
      ))
        from app.resource_occupancies o
       where o.tenant_id = target_tenant_id and o.unit_id = target_unit_id and o.status = 'ACTIVE'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.schedule_create_hold(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
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
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
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
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

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

  if not exists (
    select 1 from app.configuration_versions cv
     where cv.id = target_configuration_version_id and cv.tenant_id = target_tenant_id
  ) then
    raise exception using errcode = '42501', message = 'CONFIGURATION_NOT_ACCESSIBLE';
  end if;

  select h.* into existing
    from app.schedule_holds h
   where h.tenant_id = target_tenant_id and h.idempotency_key = target_idempotency_key;

  if existing.id is not null then
    return jsonb_build_object('holdId', existing.id, 'status', existing.status, 'expiresAt', existing.expires_at);
  end if;

  perform private.expire_stale_holds(target_tenant_id, target_unit_id);

  new_expires_at := statement_timestamp() + make_interval(secs => hold_ttl_seconds);

  insert into app.schedule_holds (
    tenant_id, unit_id, configuration_version_id, service_id, variation_id,
    starts_at, ends_at, status, plan, idempotency_key, correlation_id, expires_at, created_by
  ) values (
    target_tenant_id, target_unit_id, target_configuration_version_id, target_service_id, target_variation_id,
    target_starts_at, target_ends_at, 'ACTIVE', target_plan, target_idempotency_key, target_correlation_id,
    new_expires_at, null
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
          target_tenant_id, target_unit_id, (step ->> 'memberId')::uuid, 'HOLD', new_hold_id,
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
            target_tenant_id, target_unit_id, (resource_req ->> 'resourceId')::uuid, chosen_slot, 'HOLD', new_hold_id,
            tstzrange(step_start, step_end, '[)'), 'ACTIVE', new_expires_at, target_correlation_id
          );
          claimed := claimed + 1;
        exception when exclusion_violation then
          null;
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
    target_tenant_id, 'USER', null, 'SCHEDULE_HOLD_CREATED', 'schedule_hold', new_hold_id,
    target_configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object('unitId', target_unit_id, 'serviceId', target_service_id, 'actorEmail', lower(trim(target_email)))
  );

  return jsonb_build_object('holdId', new_hold_id, 'status', 'ACTIVE', 'expiresAt', new_expires_at);
end;
$$;

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

  select h.* into hold_record from app.schedule_holds h
   where h.id = target_hold_id and h.tenant_id = target_tenant_id
   for update;

  if hold_record.id is null then
    raise exception using errcode = '42501', message = 'HOLD_NOT_ACCESSIBLE';
  end if;

  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  if hold_record.status = 'CONVERTED' then
    select a.id, a.status into existing_appointment_id, existing_status
      from app.appointments a where a.source_hold_id = hold_record.id;
    return jsonb_build_object('appointmentId', existing_appointment_id, 'status', existing_status);
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
    target_correlation_id, null
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
    hold_record.tenant_id, 'USER', null, 'SCHEDULE_HOLD_CONFIRMED', 'appointment', new_appointment_id,
    hold_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object('holdId', hold_record.id, 'actorEmail', lower(trim(target_email)))
  );

  return jsonb_build_object('appointmentId', new_appointment_id, 'status', 'CONFIRMED');
end;
$$;

create or replace function public.schedule_cancel_hold(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_hold_id uuid,
  target_correlation_id text
)
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

  select h.* into hold_record from app.schedule_holds h
   where h.id = target_hold_id and h.tenant_id = target_tenant_id
   for update;

  if hold_record.id is null then
    raise exception using errcode = '42501', message = 'HOLD_NOT_ACCESSIBLE';
  end if;

  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

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
    hold_record.tenant_id, 'USER', null, 'SCHEDULE_HOLD_CANCELLED', 'schedule_hold', hold_record.id,
    hold_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object('actorEmail', lower(trim(target_email)))
  );
end;
$$;

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
as $$
declare
  appointment_record app.appointments%rowtype;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select a.* into appointment_record from app.appointments a
   where a.id = target_appointment_id and a.tenant_id = target_tenant_id
   for update;

  if appointment_record.id is null then
    raise exception using errcode = '42501', message = 'APPOINTMENT_NOT_ACCESSIBLE';
  end if;

  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

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
    appointment_record.tenant_id, 'USER', null, 'APPOINTMENT_CANCELLED', 'appointment', appointment_record.id,
    appointment_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object('actorEmail', lower(trim(target_email)))
  );
end;
$$;

revoke all on function public.schedule_list_occupancies(text, text, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.schedule_create_hold(text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, jsonb, text, text, integer)
  from public, anon, authenticated, service_role;
revoke all on function public.schedule_confirm_hold(text, text, uuid, uuid, text, text, uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.schedule_cancel_hold(text, text, uuid, uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.schedule_cancel_appointment(text, text, uuid, uuid, text)
  from public, anon, authenticated, service_role;

grant execute on function public.schedule_list_occupancies(text, text, uuid, uuid) to service_role;
grant execute on function public.schedule_create_hold(text, text, uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, jsonb, text, text, integer) to service_role;
grant execute on function public.schedule_confirm_hold(text, text, uuid, uuid, text, text, uuid, text) to service_role;
grant execute on function public.schedule_cancel_hold(text, text, uuid, uuid, text) to service_role;
grant execute on function public.schedule_cancel_appointment(text, text, uuid, uuid, text) to service_role;

commit;
