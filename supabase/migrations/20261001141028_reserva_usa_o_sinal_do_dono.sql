-- SINAL PASSO 3: A RESERVA USA O QUE O DONO DECIDIU NO EDDY.
--
-- schedule_confirm_hold lia app.service_deposit_policies, que nada preenche
-- (0 linhas no DEV) e é por versão publicada. Agora a regra vem de
-- app.sinal_da_reserva: valor do procedimento, período, prazo (24h/48h do
-- dono, nunca depois de 2h antes do horário) e "em cima da hora marca sem
-- sinal". Com sinal, o agendamento nasce PENDING_SIGNAL: segura o horário
-- (ninguém mais marca por cima) e só vai para o Google quando pagar.
-- O resto da função é o mesmo de antes, linha por linha.
create or replace function public.schedule_confirm_hold(
  target_site_project_id text, target_email text, target_tenant_id uuid, target_hold_id uuid,
  target_correlation_id text, target_customer_label text default null::text,
  target_channel_connection_id uuid default null::uuid, target_external_contact_ref text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  hold_record app.schedule_holds%rowtype;
  existing_appointment app.appointments%rowtype;
  existing_deposit app.appointment_deposits%rowtype;
  policy_kind app.deposit_policy_kind := 'NONE';
  policy_value integer := 0;
  policy_due_within_minutes integer;
  policy_currency char(3) := 'BRL';
  sinal jsonb;
  service_name text;
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

  -- O SINAL DO DONO.
  select service_snapshot ->> 'name',
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
    into service_name, service_price_cents, service_currency
    from app.configuration_versions version_record
    cross join lateral jsonb_array_elements(coalesce(version_record.snapshot -> 'services', '[]'::jsonb)) service_snapshot
   where version_record.id = hold_record.configuration_version_id
     and version_record.tenant_id = hold_record.tenant_id
     and service_snapshot ->> 'id' = hold_record.service_id::text;

  sinal := app.sinal_da_reserva(hold_record.tenant_id, coalesce(service_name, ''), hold_record.starts_at);

  if coalesce((sinal ->> 'cobra')::boolean, false) then
    deposit_amount_cents := (sinal ->> 'valorCentavos')::integer;
    -- Sinal maior que o preço (o preço baixou depois): cobra o preço inteiro.
    if service_price_cents is not null and service_price_cents > 0 then
      deposit_amount_cents := least(deposit_amount_cents, service_price_cents);
    end if;
    if deposit_amount_cents > 0 and coalesce(service_currency, 'BRL') = 'BRL' then
      policy_kind := 'FIXED_CENTS';
      policy_value := deposit_amount_cents;
      policy_due_within_minutes := greatest((sinal ->> 'prazoMinutos')::integer, 1);
      deposit_due_at := (sinal ->> 'prazo')::timestamptz;
      deposit_status := 'PENDING';
      appointment_status := 'PENDING_SIGNAL';
    else
      deposit_amount_cents := 0;
    end if;
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
    hold_record.tenant_id, new_appointment_id, policy_kind, policy_value,
    policy_due_within_minutes, deposit_amount_cents, policy_currency,
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
      'sinal', sinal,
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
      'currency', policy_currency,
      'dueAt', deposit_due_at
    )
  );
end;
$function$;