-- ============================================================================
-- G3.2: durable, tenant-scoped and idempotent Meta WhatsApp webhook inbox.
-- This migration is additive. It does not connect Meta or apply any secret.
-- ============================================================================

alter table app.whatsapp_channels
  add constraint whatsapp_channels_tenant_id_id_unique unique (tenant_id, id);

-- A Meta Phone Number ID identifies exactly one official WhatsApp channel.
-- Enforcing this globally prevents an inbound event from being projected into
-- two tenants by configuration error.
create unique index whatsapp_channels_phone_number_id_global_key
  on app.whatsapp_channels (phone_number_id);

create table app.whatsapp_webhook_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete cascade,
  channel_id uuid not null,
  event_key text not null check (char_length(event_key) between 1 and 240),
  event_type text not null check (char_length(event_type) between 1 and 160),
  provider_message_id text,
  payload_sha256 text not null check (payload_sha256 ~ '^[a-f0-9]{64}$'),
  payload_minimized jsonb not null default '{}'::jsonb,
  status text not null default 'RECEIVED'
    check (status in ('RECEIVED', 'PROCESSED', 'IGNORED')),
  correlation_id uuid not null,
  received_at timestamptz not null default statement_timestamp(),
  processed_at timestamptz,
  constraint whatsapp_webhook_events_tenant_channel_fkey
    foreign key (tenant_id, channel_id)
    references app.whatsapp_channels (tenant_id, id)
    on delete cascade,
  constraint whatsapp_webhook_events_tenant_event_key_key
    unique (tenant_id, event_key)
);

create index whatsapp_webhook_events_tenant_received_idx
  on app.whatsapp_webhook_events (tenant_id, received_at desc);

create index whatsapp_webhook_events_channel_received_idx
  on app.whatsapp_webhook_events (channel_id, received_at desc);

alter table app.whatsapp_webhook_events enable row level security;
alter table app.whatsapp_webhook_events force row level security;

revoke all on app.whatsapp_webhook_events from public, anon, authenticated;
grant all on app.whatsapp_webhook_events to service_role;

create or replace function public.ingest_g3_whatsapp_webhook(
  p_waba_id text,
  p_phone_number_id text,
  p_payload_sha256 text,
  p_correlation_id uuid,
  p_events jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_channel app.whatsapp_channels%rowtype;
  v_event jsonb;
  v_event_id uuid;
  v_contact_id uuid;
  v_conversation_id uuid;
  v_event_key text;
  v_event_type text;
  v_kind text;
  v_message_id text;
  v_contact_phone text;
  v_contact_name text;
  v_body text;
  v_status text;
  v_inserted integer;
  v_accepted integer := 0;
  v_duplicates integer := 0;
  v_ignored integer := 0;
begin
  if p_waba_id is null or char_length(trim(p_waba_id)) not between 1 and 160
    or p_phone_number_id is null or char_length(trim(p_phone_number_id)) not between 1 and 160
    or p_payload_sha256 is null or p_payload_sha256 !~ '^[a-f0-9]{64}$'
    or p_correlation_id is null
    or p_events is null or jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_G3_WEBHOOK_INPUT';
  end if;

  select channel.*
    into v_channel
  from app.whatsapp_channels channel
  where channel.waba_id = trim(p_waba_id)
    and channel.phone_number_id = trim(p_phone_number_id)
    and channel.status = 'ACTIVE';

  if not found then
    return jsonb_build_object(
      'knownChannel', false,
      'accepted', 0,
      'duplicates', 0,
      'ignored', 0
    );
  end if;

  for v_event in select value from jsonb_array_elements(p_events)
  loop
    v_event_key := v_event ->> 'eventKey';
    v_event_type := v_event ->> 'eventType';
    v_kind := v_event ->> 'kind';
    v_message_id := nullif(v_event ->> 'messageId', '');
    v_contact_phone := nullif(v_event ->> 'contactPhone', '');
    v_contact_name := nullif(v_event ->> 'contactName', '');
    v_body := nullif(v_event ->> 'body', '');
    v_status := nullif(v_event ->> 'status', '');

    if jsonb_typeof(v_event) <> 'object'
      or v_event_key is null or char_length(v_event_key) not between 1 and 240
      or v_event_type is null or char_length(v_event_type) not between 1 and 160
      or v_kind not in ('INBOUND_MESSAGE', 'MESSAGE_STATUS', 'UNSUPPORTED_CHANGE')
      or (v_message_id is not null and char_length(v_message_id) > 240)
      or (v_contact_name is not null and char_length(v_contact_name) > 200) then
      raise exception using errcode = '22023', message = 'INVALID_G3_WEBHOOK_EVENT';
    end if;

    if v_kind = 'INBOUND_MESSAGE' and (
      v_message_id is null
      or v_contact_phone is null or v_contact_phone !~ '^[0-9]{8,20}$'
      or v_body is null or char_length(v_body) > 4096
    ) then
      raise exception using errcode = '22023', message = 'INVALID_G3_INBOUND_MESSAGE';
    end if;

    if v_kind = 'MESSAGE_STATUS' and (
      v_message_id is null or v_status not in ('SENT', 'DELIVERED', 'READ', 'FAILED')
    ) then
      raise exception using errcode = '22023', message = 'INVALID_G3_MESSAGE_STATUS';
    end if;

    insert into app.whatsapp_webhook_events (
      tenant_id,
      channel_id,
      event_key,
      event_type,
      provider_message_id,
      payload_sha256,
      payload_minimized,
      correlation_id
    ) values (
      v_channel.tenant_id,
      v_channel.id,
      v_event_key,
      v_event_type,
      v_message_id,
      p_payload_sha256,
      jsonb_strip_nulls(jsonb_build_object(
        'kind', v_kind,
        'messageId', v_message_id,
        'status', v_status
      )),
      p_correlation_id
    )
    on conflict (tenant_id, event_key) do nothing
    returning id into v_event_id;

    if v_event_id is null then
      v_duplicates := v_duplicates + 1;
      continue;
    end if;

    if v_kind = 'INBOUND_MESSAGE' then
      insert into app.contacts (tenant_id, phone_number, full_name)
      values (v_channel.tenant_id, v_contact_phone, v_contact_name)
      on conflict (tenant_id, phone_number) do update
        set full_name = coalesce(excluded.full_name, app.contacts.full_name)
      returning id into v_contact_id;

      insert into app.conversations (tenant_id, contact_id, status, last_message_at)
      values (v_channel.tenant_id, v_contact_id, 'OPEN', statement_timestamp())
      on conflict (tenant_id, contact_id) do update
        set last_message_at = greatest(app.conversations.last_message_at, excluded.last_message_at)
      returning id into v_conversation_id;

      insert into app.messages (
        tenant_id,
        conversation_id,
        direction,
        sender_type,
        body,
        whatsapp_message_id,
        status
      ) values (
        v_channel.tenant_id,
        v_conversation_id,
        'INBOUND',
        'CLIENT',
        v_body,
        v_message_id,
        'RECEIVED'
      )
      on conflict (tenant_id, whatsapp_message_id) where whatsapp_message_id is not null do nothing;

      get diagnostics v_inserted = row_count;
      if v_inserted = 0 then
        v_duplicates := v_duplicates + 1;
      else
        v_accepted := v_accepted + 1;
      end if;
    elsif v_kind = 'MESSAGE_STATUS' then
      update app.messages
      set status = v_status
      where tenant_id = v_channel.tenant_id
        and whatsapp_message_id = v_message_id
        and case v_status
          when 'SENT' then 1
          when 'DELIVERED' then 2
          when 'READ' then 3
          when 'FAILED' then 4
          else 0
        end >= case status
          when 'SENT' then 1
          when 'DELIVERED' then 2
          when 'READ' then 3
          when 'FAILED' then 4
          else 0
        end;

      v_accepted := v_accepted + 1;
    else
      update app.whatsapp_webhook_events
      set status = 'IGNORED', processed_at = statement_timestamp()
      where id = v_event_id;

      v_ignored := v_ignored + 1;
      continue;
    end if;

    update app.whatsapp_webhook_events
    set status = 'PROCESSED', processed_at = statement_timestamp()
    where id = v_event_id;
  end loop;

  return jsonb_build_object(
    'knownChannel', true,
    'accepted', v_accepted,
    'duplicates', v_duplicates,
    'ignored', v_ignored
  );
end;
$$;

revoke all on function public.ingest_g3_whatsapp_webhook(text, text, text, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.ingest_g3_whatsapp_webhook(text, text, text, uuid, jsonb)
  to service_role;

comment on table app.whatsapp_webhook_events is
  'Durable, tenant-scoped idempotency inbox for verified Meta WhatsApp webhook events. Raw payloads and secrets are never retained.';

comment on function public.ingest_g3_whatsapp_webhook(text, text, text, uuid, jsonb) is
  'Service-role-only atomic projection of verified and normalized Meta webhook events into the G3 inbox.';
