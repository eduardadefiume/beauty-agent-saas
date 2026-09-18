begin;

-- Bug real achado em teste: cancelar o agendamento principal deixava a
-- reserva de teste de mechas ligada a ele órfã (continuava CONFIRMED),
-- ocupando a colorista pra sempre numa data que não serve mais pra nada.
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
 set search_path to ''
as $function$
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

  update app.strand_test_bookings set status = 'CANCELLED', updated_at = statement_timestamp()
   where tenant_id = appointment_record.tenant_id and main_appointment_id = appointment_record.id and status = 'CONFIRMED';

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    appointment_record.tenant_id, 'USER', null, 'APPOINTMENT_CANCELLED', 'appointment', appointment_record.id,
    appointment_record.configuration_version_id, target_correlation_id, 'SUCCESS',
    jsonb_build_object('actorEmail', lower(trim(target_email)))
  );
end;
$function$;

commit;
