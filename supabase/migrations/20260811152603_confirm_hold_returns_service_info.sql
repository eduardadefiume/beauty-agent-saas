begin;

-- schedule_confirm_hold passa a devolver serviceId/unitId/startsAt/endsAt
-- junto do appointmentId — o Edge Function precisa disso logo depois de
-- confirmar pra decidir (sem outra chamada) se esse serviço exige teste de
-- mechas e, se exigir, tentar agendar o teste automaticamente.
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
 set search_path to ''
as $function$
declare
  hold_record app.schedule_holds%rowtype;
  existing_appointment_id uuid;
  existing_status app.appointment_status;
  existing_unit_id uuid;
  existing_service_id uuid;
  existing_starts_at timestamptz;
  existing_ends_at timestamptz;
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
    select a.id, a.status, a.unit_id, a.service_id, a.starts_at, a.ends_at
      into existing_appointment_id, existing_status, existing_unit_id, existing_service_id, existing_starts_at, existing_ends_at
      from app.appointments a where a.source_hold_id = hold_record.id;
    return jsonb_build_object(
      'appointmentId', existing_appointment_id,
      'status', existing_status,
      'unitId', existing_unit_id,
      'serviceId', existing_service_id,
      'startsAt', existing_starts_at,
      'endsAt', existing_ends_at
    );
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

  return jsonb_build_object(
    'appointmentId', new_appointment_id,
    'status', 'CONFIRMED',
    'unitId', hold_record.unit_id,
    'serviceId', hold_record.service_id,
    'startsAt', hold_record.starts_at,
    'endsAt', hold_record.ends_at
  );
end;
$function$;

commit;
