begin;

create or replace function api.ingest_whatsapp_webhook(
  p_waba_id text,
  p_phone_number_id text,
  p_payload_sha256 text,
  p_correlation_id text,
  p_events jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_connection app.channel_connections%rowtype;
  event_record jsonb;
  event_contact text;
  contact_required boolean;
  is_authorized boolean;
  safe_payload jsonb;
  inserted_rows integer;
  accepted_count integer := 0;
  rejected_count integer := 0;
  duplicate_count integer := 0;
  incoming_external_event_id text;
  incoming_event_type text;
begin
  if p_waba_id is null or length(trim(p_waba_id)) = 0
    or p_phone_number_id is null or length(trim(p_phone_number_id)) = 0
    or p_payload_sha256 is null
    or p_payload_sha256 !~ '^[a-f0-9]{64}$'
    or p_correlation_id is null or length(p_correlation_id) not between 8 and 128
    or p_events is null
    or jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_WHATSAPP_WEBHOOK_INPUT';
  end if;

  select connection.*
    into target_connection
  from app.channel_connections connection
  where connection.channel = 'WHATSAPP'
    and connection.external_account_id = trim(p_waba_id)
    and connection.external_sender_id = trim(p_phone_number_id)
    and connection.status in ('SANDBOX_CONNECTED', 'CONTROLLED_PRODUCTION', 'PRODUCTION')
  limit 1;

  if not found then
    return jsonb_build_object(
      'knownConnection', false,
      'accepted', 0,
      'rejected', 0,
      'duplicates', 0
    );
  end if;

  for event_record in select value from jsonb_array_elements(p_events)
  loop
    incoming_external_event_id := event_record ->> 'externalEventId';
    incoming_event_type := event_record ->> 'eventType';
    event_contact := regexp_replace(coalesce(event_record ->> 'contact', ''), '[^0-9]', '', 'g');

    if incoming_external_event_id is null
      or length(trim(incoming_external_event_id)) not between 1 and 240
      or incoming_event_type is null
      or length(trim(incoming_event_type)) not between 1 and 160
      or jsonb_typeof(coalesce(event_record -> 'payload', '{}'::jsonb)) <> 'object' then
      raise exception using errcode = '22023', message = 'INVALID_WHATSAPP_EVENT';
    end if;

    contact_required := incoming_event_type like 'WHATSAPP_MESSAGE_%'
      or incoming_event_type like 'WHATSAPP_STATUS_%';
    is_authorized := (not contact_required and event_contact = '') or (
      event_contact <> '' and exists (
        select 1
        from app.channel_allowlist allowlist
        where allowlist.tenant_id = target_connection.tenant_id
          and allowlist.connection_id = target_connection.id
          and allowlist.normalized_contact = event_contact
          and allowlist.status = 'ACTIVE'
          and (allowlist.expires_at is null or allowlist.expires_at > statement_timestamp())
      )
    );

    safe_payload := case
      when is_authorized then coalesce(event_record -> 'payload', '{}'::jsonb)
      else jsonb_build_object(
        'externalEventId', incoming_external_event_id,
        'eventType', incoming_event_type,
        'reason', 'CONTACT_NOT_ALLOWLISTED'
      )
    end;

    insert into app.inbox_events (
      tenant_id,
      connection_id,
      provider,
      external_event_id,
      event_type,
      payload,
      payload_sha256,
      contact_authorized,
      status,
      rejection_reason,
      correlation_id,
      processed_at
    ) values (
      target_connection.tenant_id,
      target_connection.id,
      'WHATSAPP',
      incoming_external_event_id,
      incoming_event_type,
      safe_payload,
      p_payload_sha256,
      is_authorized,
      case when is_authorized then 'PENDING'::app.inbox_event_status else 'REJECTED'::app.inbox_event_status end,
      case when is_authorized then null else 'CONTACT_NOT_ALLOWLISTED' end,
      p_correlation_id,
      case when is_authorized then null else statement_timestamp() end
    )
    on conflict (tenant_id, connection_id, provider, external_event_id) do nothing;

    get diagnostics inserted_rows = row_count;
    if inserted_rows = 0 then
      duplicate_count := duplicate_count + 1;
    elsif is_authorized then
      accepted_count := accepted_count + 1;
    else
      rejected_count := rejected_count + 1;
    end if;
  end loop;

  if accepted_count + rejected_count > 0 then
    update app.channel_connections
    set last_webhook_at = statement_timestamp()
    where id = target_connection.id;

    insert into app.audit_logs (
      tenant_id,
      actor_type,
      action,
      entity_type,
      correlation_id,
      result,
      metadata_minimized
    ) values (
      target_connection.tenant_id,
      'SYSTEM',
      'WHATSAPP_WEBHOOK_INGESTED',
      'INBOX_EVENT',
      p_correlation_id,
      case when rejected_count > 0 and accepted_count = 0 then 'DENIED'::app.audit_result else 'SUCCESS'::app.audit_result end,
      jsonb_build_object(
        'acceptedCount', accepted_count,
        'rejectedCount', rejected_count,
        'duplicateCount', duplicate_count
      )
    );
  end if;

  return jsonb_build_object(
    'knownConnection', true,
    'accepted', accepted_count,
    'rejected', rejected_count,
    'duplicates', duplicate_count
  );
end;
$$;

revoke all on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  to service_role;

commit;
