begin;

-- A expiração é um evento de sistema distinto de cancelamento humano. O evento
-- preserva a origem e a chave determinística para reexecução segura.
alter table app.appointment_deposit_events
  drop constraint if exists appointment_deposit_events_event_source_check;

alter table app.appointment_deposit_events
  add constraint appointment_deposit_events_event_source_check
  check (event_source in ('MANUAL_VERIFIED', 'SYSTEM_CANCELLATION', 'SYSTEM_EXPIRATION'));

-- Esta função torna a expiração segura para um worker futuro. Ela não agenda
-- nenhuma execução por conta própria: o agendador persistente será definido em
-- uma fatia de infraestrutura separada.
create or replace function public.schedule_expire_due_deposits(
  target_correlation_id text,
  target_limit integer default 100
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  deposit_record app.appointment_deposits%rowtype;
  appointment_record app.appointments%rowtype;
  event_inserted boolean;
  processed_count integer := 0;
begin
  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;
  if target_limit is null or target_limit not between 1 and 1000 then
    raise exception using errcode = '22023', message = 'INVALID_EXPIRATION_LIMIT';
  end if;

  for deposit_record in
    select d.*
      from app.appointment_deposits d
      join app.appointments a
        on a.tenant_id = d.tenant_id
       and a.id = d.appointment_id
     where d.status = 'PENDING'
       and d.due_at < statement_timestamp()
       and a.status = 'PENDING_SIGNAL'
     order by d.due_at, d.id
     limit target_limit
     for update of d skip locked
  loop
    select a.* into appointment_record
      from app.appointments a
     where a.tenant_id = deposit_record.tenant_id
       and a.id = deposit_record.appointment_id
     for update;

    -- A revalidação é necessária porque o registro de agendamento pode ter sido
    -- confirmado ou cancelado entre a seleção e o lock exclusivo.
    if appointment_record.id is null
      or appointment_record.status <> 'PENDING_SIGNAL'
      or deposit_record.status <> 'PENDING'
      or deposit_record.due_at is null
      or deposit_record.due_at >= statement_timestamp() then
      continue;
    end if;

    insert into app.appointment_deposit_events (
      tenant_id, appointment_deposit_id, appointment_id, event_source,
      external_event_ref, resulting_status, correlation_id, actor_type, actor_id,
      metadata_minimized
    ) values (
      deposit_record.tenant_id, deposit_record.id, appointment_record.id, 'SYSTEM_EXPIRATION',
      deposit_record.id::text || ':expired', 'EXPIRED', target_correlation_id, 'WORKER', null,
      jsonb_build_object('reason', 'DUE_AT_ELAPSED')
    ) on conflict (tenant_id, event_source, external_event_ref) do nothing
    returning true into event_inserted;

    -- Um evento já existente prova que outra tentativa concluiu a transição; a
    -- condição de status impede que a repetição volte a tocar efeitos terminais.
    if coalesce(event_inserted, false) = false then
      continue;
    end if;

    update app.appointment_deposits
       set status = 'EXPIRED'
     where id = deposit_record.id
       and tenant_id = deposit_record.tenant_id
       and status = 'PENDING';

    update app.appointments
       set status = 'CANCELLED', updated_at = statement_timestamp()
     where id = appointment_record.id
       and tenant_id = appointment_record.tenant_id
       and status = 'PENDING_SIGNAL';

    update app.member_occupancies
       set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = appointment_record.tenant_id
       and source_type = 'APPOINTMENT'
       and source_id = appointment_record.id
       and status = 'ACTIVE';

    update app.resource_occupancies
       set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = appointment_record.tenant_id
       and source_type = 'APPOINTMENT'
       and source_id = appointment_record.id
       and status = 'ACTIVE';

    update app.strand_test_bookings
       set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = appointment_record.tenant_id
       and main_appointment_id = appointment_record.id
       and status in ('SCHEDULED', 'COMPLETED');

    insert into app.audit_logs (
      tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
      correlation_id, result, metadata_minimized
    ) values (
      appointment_record.tenant_id, 'WORKER', null, 'APPOINTMENT_DEPOSIT_EXPIRED', 'appointment',
      appointment_record.id, appointment_record.configuration_version_id, target_correlation_id,
      'SUCCESS', jsonb_build_object('depositId', deposit_record.id, 'reason', 'DUE_AT_ELAPSED')
    );

    processed_count := processed_count + 1;
  end loop;

  return processed_count;
end;
$function$;

revoke all on function public.schedule_expire_due_deposits(text, integer)
  from public, anon, authenticated;
grant execute on function public.schedule_expire_due_deposits(text, integer) to service_role;

commit;
