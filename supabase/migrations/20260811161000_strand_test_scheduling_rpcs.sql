begin;

-- Ocupações de teste de mechas já marcadas — só para o motor evitar marcar
-- duas colorações de teste em cima uma da outra pra mesma colorista/cadeira.
-- Separado de schedule_list_occupancies de propósito: a busca de horário
-- NORMAL (searchSlots) nunca deve enxergar isso, porque teste não bloqueia
-- atendimento (pedido explícito da Duda).
create function public.schedule_list_strand_test_occupancies(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  return jsonb_build_object(
    'memberOccupancies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', b.member_id,
        'startMs', floor(extract(epoch from lower(b.time_range)) * 1000),
        'endMs', floor(extract(epoch from upper(b.time_range)) * 1000)
      ))
        from app.strand_test_bookings b
       where b.tenant_id = target_tenant_id and b.unit_id = target_unit_id and b.status = 'CONFIRMED'
    ), '[]'::jsonb),
    'resourceOccupancies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'resourceId', b.resource_id,
        'startMs', floor(extract(epoch from lower(b.time_range)) * 1000),
        'endMs', floor(extract(epoch from upper(b.time_range)) * 1000)
      ))
        from app.strand_test_bookings b
       where b.tenant_id = target_tenant_id and b.unit_id = target_unit_id and b.status = 'CONFIRMED'
         and b.resource_id is not null
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.schedule_list_strand_test_occupancies(text, text, uuid, uuid) to service_role;

-- Grava a reserva do teste de mechas achada pelo motor (Edge Function já
-- rodou a busca em TypeScript — esta RPC só persiste o resultado). Idempotente
-- por (tenant_id, main_appointment_id): uma segunda tentativa pro mesmo
-- agendamento principal não duplica. Se o horário escolhido colidir com
-- outra reserva de teste da mesma colorista sob corrida (exclusion
-- constraint), devolve scheduled=false em vez de estourar erro — o
-- confirmHold não pode falhar por causa do teste.
create function public.schedule_record_strand_test_booking(
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
  new_id uuid;
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
    on conflict (tenant_id, main_appointment_id) do nothing
    returning id into new_id;
  exception
    when exclusion_violation then
      return jsonb_build_object('scheduled', false, 'reason', 'STRAND_TEST_SLOT_TAKEN');
  end;

  if new_id is null then
    -- Já existia (retry idempotente) — devolve a reserva existente.
    select id into new_id from app.strand_test_bookings
     where tenant_id = target_tenant_id and main_appointment_id = target_main_appointment_id;
  end if;

  return jsonb_build_object('scheduled', true, 'strandTestBookingId', new_id);
end;
$function$;

grant execute on function public.schedule_record_strand_test_booking(
  text, text, uuid, uuid, uuid, uuid, text, uuid, timestamptz, timestamptz, text
) to service_role;

commit;
