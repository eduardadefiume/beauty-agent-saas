begin;

create type app.channel_connection_status as enum (
  'DISCONNECTED',
  'SANDBOX_CONNECTED',
  'CONTROLLED_PRODUCTION',
  'PRODUCTION',
  'SUSPENDED'
);
create type app.inbox_event_status as enum ('PENDING', 'PROCESSING', 'PROCESSED', 'REJECTED', 'FAILED');

create table app.channel_connections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  channel text not null check (channel = 'WHATSAPP'),
  external_account_id text not null check (length(trim(external_account_id)) between 1 and 160),
  external_sender_id text not null check (length(trim(external_sender_id)) between 1 and 160),
  credential_ref text check (credential_ref is null or length(trim(credential_ref)) between 1 and 240),
  mode text not null default 'RESTRICTED' check (mode = 'RESTRICTED'),
  status app.channel_connection_status not null default 'DISCONNECTED',
  last_webhook_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, id),
  unique (channel, external_account_id, external_sender_id)
);

create table app.channel_allowlist (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  connection_id uuid not null,
  normalized_contact text not null check (normalized_contact ~ '^[0-9]{8,15}$'),
  status app.record_status not null default 'ACTIVE',
  expires_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, connection_id, normalized_contact),
  foreign key (tenant_id, connection_id)
    references app.channel_connections(tenant_id, id) on delete cascade
);

create table app.inbox_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  connection_id uuid not null,
  provider text not null check (provider = 'WHATSAPP'),
  external_event_id text not null check (length(trim(external_event_id)) between 1 and 240),
  event_type text not null check (length(trim(event_type)) between 1 and 160),
  payload jsonb not null,
  payload_sha256 text not null check (payload_sha256 ~ '^[a-f0-9]{64}$'),
  contact_authorized boolean not null,
  status app.inbox_event_status not null default 'PENDING',
  rejection_reason text,
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  received_at timestamptz not null default statement_timestamp(),
  processed_at timestamptz,
  foreign key (tenant_id, connection_id)
    references app.channel_connections(tenant_id, id) on delete restrict,
  unique (tenant_id, connection_id, provider, external_event_id),
  check ((status = 'REJECTED') = (rejection_reason is not null)),
  check (processed_at is null or status in ('PROCESSED', 'REJECTED', 'FAILED'))
);

create index channel_connections_tenant_status_idx
  on app.channel_connections (tenant_id, status);
create index channel_allowlist_connection_active_idx
  on app.channel_allowlist (tenant_id, connection_id, normalized_contact)
  where status = 'ACTIVE';
create index inbox_events_pending_idx
  on app.inbox_events (tenant_id, received_at, id)
  where status = 'PENDING';
create index inbox_events_correlation_idx
  on app.inbox_events (correlation_id);

create trigger channel_connections_touch_updated_at
before update on app.channel_connections
for each row execute function private.touch_updated_at();

create trigger channel_allowlist_touch_updated_at
before update on app.channel_allowlist
for each row execute function private.touch_updated_at();

alter table app.channel_connections enable row level security;
alter table app.channel_connections force row level security;
alter table app.channel_allowlist enable row level security;
alter table app.channel_allowlist force row level security;
alter table app.inbox_events enable row level security;
alter table app.inbox_events force row level security;

create policy channel_connections_select_admin
on app.channel_connections for select to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[]));

create policy channel_allowlist_select_admin
on app.channel_allowlist for select to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[]));

create policy inbox_events_select_admin
on app.inbox_events for select to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[]));

revoke all on app.channel_connections, app.channel_allowlist, app.inbox_events
  from public, anon, authenticated;
grant select on app.channel_connections, app.channel_allowlist, app.inbox_events
  to authenticated;
grant select, insert, update, delete on app.channel_connections, app.channel_allowlist, app.inbox_events
  to service_role;

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
  normalized_contact text;
  is_authorized boolean;
  safe_payload jsonb;
  inserted_rows integer;
  accepted_count integer := 0;
  rejected_count integer := 0;
  duplicate_count integer := 0;
  external_event_id text;
  event_type text;
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
    external_event_id := event_record ->> 'externalEventId';
    event_type := event_record ->> 'eventType';
    normalized_contact := regexp_replace(coalesce(event_record ->> 'contact', ''), '[^0-9]', '', 'g');

    if external_event_id is null or length(trim(external_event_id)) not between 1 and 240
      or event_type is null or length(trim(event_type)) not between 1 and 160
      or jsonb_typeof(coalesce(event_record -> 'payload', '{}'::jsonb)) <> 'object' then
      raise exception using errcode = '22023', message = 'INVALID_WHATSAPP_EVENT';
    end if;

    is_authorized := normalized_contact = '' or exists (
      select 1
      from app.channel_allowlist allowlist
      where allowlist.tenant_id = target_connection.tenant_id
        and allowlist.connection_id = target_connection.id
        and allowlist.normalized_contact = normalized_contact
        and allowlist.status = 'ACTIVE'
        and (allowlist.expires_at is null or allowlist.expires_at > statement_timestamp())
    );

    safe_payload := case
      when is_authorized then coalesce(event_record -> 'payload', '{}'::jsonb)
      else jsonb_build_object(
        'externalEventId', external_event_id,
        'eventType', event_type,
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
      external_event_id,
      event_type,
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
grant usage on schema api to service_role;
grant execute on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  to service_role;

comment on table app.channel_connections is
  'Tenant-bound official messaging channel connection. Credentials are referenced, never stored here.';
comment on table app.channel_allowlist is
  'Restricted-pilot contacts. Access is tenant-admin only and service-side writes only.';
comment on table app.inbox_events is
  'Durable idempotent webhook inbox. Unauthorized contacts retain only a minimized rejection payload.';
comment on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb) is
  'Service-role-only transaction that maps Meta account identifiers to a tenant and persists idempotent events.';

commit;
