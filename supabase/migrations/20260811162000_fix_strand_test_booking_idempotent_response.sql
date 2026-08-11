begin;

-- Bug real achado em teste: numa segunda chamada idempotente pro mesmo
-- agendamento principal, a RPC devolvia scheduled=true mas com o horário do
-- NOVO candidato que o motor acabou de recalcular (que nem foi gravado,
-- porque o insert bateu no on conflict do nothing) — não o horário
-- REALMENTE salvo na primeira vez. Corrigido: sempre devolve os dados da
-- linha que está de fato na tabela, seja ela recém-inserida ou já
-- existente.
create or replace function public.schedule_record_strand_test_booking(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid,
  target_main_appointment_id uuid,
  target_member_id uuid,
  target_member_name text,
  target_resource_id uuid,
  target_starts_at timestamptz,
  target_ends_at timestamptz,
  target_correlation_id text
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  saved app.strand_test_bookings%rowtype;
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;
  if target_ends_at <= target_starts_at then
    raise exception using errcode = '22023', message = 'INVALID_STRAND_TEST_RANGE';
  end if;

  begin
    insert into app.strand_test_bookings (
      tenant_id, unit_id, main_appointment_id, member_id, member_name, resource_id,
      time_range, status, correlation_id
    ) values (
      target_tenant_id, target_unit_id, target_main_appointment_id, target_member_id, target_member_name,
      target_resource_id, tstzrange(target_starts_at, target_ends_at, '[)'), 'CONFIRMED', target_correlation_id
    )
    on conflict (tenant_id, main_appointment_id) do nothing;
  exception
    when exclusion_violation then
      return jsonb_build_object('scheduled', false, 'reason', 'STRAND_TEST_SLOT_TAKEN');
  end;

  select * into saved from app.strand_test_bookings
   where tenant_id = target_tenant_id and main_appointment_id = target_main_appointment_id;

  if saved.id is null then
    -- Não deveria acontecer (nem inseriu nem já existia), mas não é motivo
    -- pra estourar erro no confirmHold — trata como não agendado.
    return jsonb_build_object('scheduled', false, 'reason', 'STRAND_TEST_SLOT_TAKEN');
  end if;

  return jsonb_build_object(
    'scheduled', true,
    'strandTestBookingId', saved.id,
    'startsAt', lower(saved.time_range),
    'endsAt', upper(saved.time_range),
    'memberName', saved.member_name
  );
end;
$function$;

commit;
