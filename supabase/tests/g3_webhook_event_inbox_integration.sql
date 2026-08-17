begin;

insert into app.tenants (id, display_name, slug)
values
  ('f3600000-0000-0000-0000-000000000001', 'G3.2 Tenant Alpha', 'g32-tenant-alpha'),
  ('f3600000-0000-0000-0000-000000000002', 'G3.2 Tenant Beta', 'g32-tenant-beta');

insert into app.whatsapp_channels (
  id, tenant_id, phone_number_id, waba_id, access_token_encrypted
) values
  (
    'f3610000-0000-0000-0000-000000000001',
    'f3600000-0000-0000-0000-000000000001',
    'g32-test-phone-alpha',
    'g32-test-waba-alpha',
    'key_ref:integration-test-only'
  ),
  (
    'f3610000-0000-0000-0000-000000000002',
    'f3600000-0000-0000-0000-000000000002',
    'g32-test-phone-beta',
    'g32-test-waba-beta',
    'key_ref:integration-test-only'
  );

do $$
declare
  inbound_event jsonb := jsonb_build_array(jsonb_build_object(
    'eventKey', 'wamid.g32-inbound-001',
    'eventType', 'messages.text',
    'kind', 'INBOUND_MESSAGE',
    'messageId', 'wamid.g32-inbound-001',
    'contactPhone', '5516994215487',
    'contactName', 'Piloto G3',
    'body', 'SMOKE G3.2',
    'status', null
  ));
  first_result jsonb;
  duplicate_result jsonb;
  delivered_result jsonb;
  sent_result jsonb;
begin
  select public.ingest_g3_whatsapp_webhook(
    'g32-test-waba-alpha',
    'g32-test-phone-alpha',
    repeat('a', 64),
    'f3620000-0000-0000-0000-000000000001',
    inbound_event
  ) into first_result;

  if first_result <> jsonb_build_object('knownChannel', true, 'accepted', 1, 'duplicates', 0, 'ignored', 0) then
    raise exception 'G32_FIRST_INGESTION_INVALID_%', first_result;
  end if;

  select public.ingest_g3_whatsapp_webhook(
    'g32-test-waba-alpha',
    'g32-test-phone-alpha',
    repeat('a', 64),
    'f3620000-0000-0000-0000-000000000002',
    inbound_event
  ) into duplicate_result;

  if duplicate_result <> jsonb_build_object('knownChannel', true, 'accepted', 0, 'duplicates', 1, 'ignored', 0) then
    raise exception 'G32_DUPLICATE_NOT_ABSORBED_%', duplicate_result;
  end if;

  if (select count(*) from app.whatsapp_webhook_events where tenant_id = 'f3600000-0000-0000-0000-000000000001') <> 1
    or (select count(*) from app.contacts where tenant_id = 'f3600000-0000-0000-0000-000000000001') <> 1
    or (select count(*) from app.conversations where tenant_id = 'f3600000-0000-0000-0000-000000000001') <> 1
    or (select count(*) from app.messages where tenant_id = 'f3600000-0000-0000-0000-000000000001') <> 1 then
    raise exception 'G32_INBOUND_PROJECTION_NOT_IDEMPOTENT';
  end if;

  select public.ingest_g3_whatsapp_webhook(
    'g32-test-waba-alpha',
    'g32-test-phone-alpha',
    repeat('b', 64),
    'f3620000-0000-0000-0000-000000000003',
    jsonb_build_array(jsonb_build_object(
      'eventKey', 'status.wamid.g32-inbound-001.delivered',
      'eventType', 'statuses.delivered',
      'kind', 'MESSAGE_STATUS',
      'messageId', 'wamid.g32-inbound-001',
      'status', 'DELIVERED'
    ))
  ) into delivered_result;

  if delivered_result ->> 'accepted' <> '1' then
    raise exception 'G32_DELIVERED_STATUS_NOT_ACCEPTED_%', delivered_result;
  end if;

  select public.ingest_g3_whatsapp_webhook(
    'g32-test-waba-alpha',
    'g32-test-phone-alpha',
    repeat('c', 64),
    'f3620000-0000-0000-0000-000000000004',
    jsonb_build_array(jsonb_build_object(
      'eventKey', 'status.wamid.g32-inbound-001.sent',
      'eventType', 'statuses.sent',
      'kind', 'MESSAGE_STATUS',
      'messageId', 'wamid.g32-inbound-001',
      'status', 'SENT'
    ))
  ) into sent_result;

  if sent_result ->> 'accepted' <> '1'
    or (select status from app.messages where tenant_id = 'f3600000-0000-0000-0000-000000000001' and whatsapp_message_id = 'wamid.g32-inbound-001') <> 'DELIVERED' then
    raise exception 'G32_STATUS_REGRESSION_ALLOWED_%', sent_result;
  end if;

  if exists (
    select 1 from app.customer_consents
    where tenant_id = 'f3600000-0000-0000-0000-000000000001'
      and purpose = 'MARKETING'
  ) then
    raise exception 'G32_MARKETING_CONSENT_WAS_CREATED';
  end if;

  if exists (
    select 1 from app.whatsapp_webhook_events
    where tenant_id = 'f3600000-0000-0000-0000-000000000002'
  ) then
    raise exception 'G32_CROSS_TENANT_EVENT_WAS_CREATED';
  end if;

  if not has_table_privilege('service_role', 'app.whatsapp_webhook_events', 'SELECT, INSERT, UPDATE, DELETE')
    or has_table_privilege('anon', 'app.whatsapp_webhook_events', 'SELECT')
    or has_table_privilege('authenticated', 'app.whatsapp_webhook_events', 'SELECT')
    or has_function_privilege('anon', 'public.ingest_g3_whatsapp_webhook(text, text, text, uuid, jsonb)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.ingest_g3_whatsapp_webhook(text, text, text, uuid, jsonb)', 'EXECUTE')
    or not has_function_privilege('service_role', 'public.ingest_g3_whatsapp_webhook(text, text, text, uuid, jsonb)', 'EXECUTE') then
    raise exception 'G32_GRANTS_INVALID';
  end if;
end;
$$;

rollback;

select 'G3_WEBHOOK_EVENT_INBOX_INTEGRATION_OK' as result;
