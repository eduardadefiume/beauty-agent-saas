begin;

create type app.contact_status as enum ('ACTIVE', 'ARCHIVED');
create type app.conversation_status as enum ('OPEN', 'PENDING', 'CLOSED');
create type app.message_direction as enum ('INBOUND', 'OUTBOUND');
create type app.consent_scope as enum ('TRANSACTIONAL', 'MARKETING');
create type app.consent_status as enum ('GRANTED', 'REVOKED');
create type app.campaign_status as enum ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'SCHEDULED', 'PROCESSING', 'COMPLETED', 'CANCELLED', 'FAILED');
create type app.campaign_recipient_status as enum ('PENDING', 'SKIPPED', 'QUEUED', 'SENT', 'DELIVERED', 'READ', 'FAILED');

create table app.crm_contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  unit_id uuid references app.units(id) on delete set null,
  display_name text,
  status app.contact_status not null default 'ACTIVE',
  external_contact_ref text,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint crm_contacts_tenant_id_id_unique unique (tenant_id, id),
  constraint crm_contacts_display_name_length check (display_name is null or length(trim(display_name)) between 1 and 160)
);

create unique index crm_contacts_external_ref_unique_idx
  on app.crm_contacts (tenant_id, external_contact_ref)
  where external_contact_ref is not null;
create index crm_contacts_tenant_created_idx on app.crm_contacts (tenant_id, created_at desc);

create table app.crm_contact_channels (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  contact_id uuid not null,
  channel_connection_id uuid references app.channel_connections(id) on delete set null,
  provider text not null check (provider in ('WHATSAPP')),
  address_normalized text not null check (length(trim(address_normalized)) between 4 and 80),
  is_primary boolean not null default true,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint crm_contact_channels_contact_fk foreign key (tenant_id, contact_id)
    references app.crm_contacts(tenant_id, id) on delete cascade,
  constraint crm_contact_channels_tenant_id_id_unique unique (tenant_id, id),
  constraint crm_contact_channels_address_unique unique (tenant_id, provider, address_normalized)
);

create index crm_contact_channels_contact_idx on app.crm_contact_channels (tenant_id, contact_id);

create table app.crm_conversations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  unit_id uuid references app.units(id) on delete set null,
  contact_id uuid not null,
  channel_connection_id uuid references app.channel_connections(id) on delete set null,
  external_conversation_ref text,
  status app.conversation_status not null default 'OPEN',
  last_message_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint crm_conversations_contact_fk foreign key (tenant_id, contact_id)
    references app.crm_contacts(tenant_id, id) on delete restrict,
  constraint crm_conversations_tenant_id_id_unique unique (tenant_id, id)
);

create unique index crm_conversations_external_ref_unique_idx
  on app.crm_conversations (tenant_id, channel_connection_id, external_conversation_ref)
  where external_conversation_ref is not null;
create index crm_conversations_tenant_last_message_idx on app.crm_conversations (tenant_id, last_message_at desc nulls last);

create table app.crm_messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  conversation_id uuid not null,
  direction app.message_direction not null,
  provider_message_id text,
  message_type text not null check (message_type in ('TEXT', 'TEMPLATE', 'MEDIA', 'SYSTEM')),
  body_text text,
  occurred_at timestamptz not null,
  metadata_minimized jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  constraint crm_messages_conversation_fk foreign key (tenant_id, conversation_id)
    references app.crm_conversations(tenant_id, id) on delete cascade,
  constraint crm_messages_tenant_id_id_unique unique (tenant_id, id),
  constraint crm_messages_body_length check (body_text is null or length(body_text) <= 4096)
);

create unique index crm_messages_provider_id_unique_idx
  on app.crm_messages (tenant_id, provider_message_id)
  where provider_message_id is not null;
create index crm_messages_conversation_occurred_idx on app.crm_messages (tenant_id, conversation_id, occurred_at desc);

create table app.crm_contact_consents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  contact_id uuid not null,
  channel_id uuid references app.crm_contact_channels(id) on delete set null,
  scope app.consent_scope not null,
  status app.consent_status not null,
  source text not null check (source in ('WHATSAPP_INBOUND', 'FORM', 'MANUAL_VERIFIED', 'IMPORT_VERIFIED')),
  evidence_ref text not null check (length(trim(evidence_ref)) between 8 and 255),
  captured_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint crm_contact_consents_contact_fk foreign key (tenant_id, contact_id)
    references app.crm_contacts(tenant_id, id) on delete cascade,
  constraint crm_contact_consents_revocation_check check (
    (status = 'GRANTED' and revoked_at is null) or (status = 'REVOKED' and revoked_at is not null)
  )
);

create index crm_contact_consents_lookup_idx
  on app.crm_contact_consents (tenant_id, contact_id, scope, captured_at desc);

create table app.campaigns (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  unit_id uuid references app.units(id) on delete set null,
  name text not null check (length(trim(name)) between 3 and 160),
  template_name text not null check (length(trim(template_name)) between 3 and 512),
  template_language text not null check (template_language ~ '^[a-z]{2}(_[A-Z]{2})?$'),
  status app.campaign_status not null default 'DRAFT',
  scheduled_for timestamptz,
  approved_at timestamptz,
  approved_by uuid references app.profiles(id) on delete set null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint campaigns_schedule_check check (
    (status in ('SCHEDULED', 'PROCESSING') and scheduled_for is not null) or status not in ('SCHEDULED', 'PROCESSING')
  )
);

create index campaigns_tenant_status_idx on app.campaigns (tenant_id, status, scheduled_for);

create table app.campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  campaign_id uuid not null references app.campaigns(id) on delete cascade,
  contact_id uuid not null,
  channel_id uuid not null,
  consent_id uuid,
  status app.campaign_recipient_status not null default 'PENDING',
  failure_code text,
  provider_message_id text,
  queued_at timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint campaign_recipients_contact_fk foreign key (tenant_id, contact_id)
    references app.crm_contacts(tenant_id, id) on delete restrict,
  constraint campaign_recipients_channel_fk foreign key (tenant_id, channel_id)
    references app.crm_contact_channels(tenant_id, id) on delete restrict,
  constraint campaign_recipients_consent_fk foreign key (consent_id)
    references app.crm_contact_consents(id) on delete restrict,
  constraint campaign_recipients_unique unique (campaign_id, contact_id)
);

create index campaign_recipients_worker_idx on app.campaign_recipients (tenant_id, status, queued_at);

create trigger crm_contacts_touch_updated_at before update on app.crm_contacts
for each row execute function private.touch_updated_at();
create trigger crm_contact_channels_touch_updated_at before update on app.crm_contact_channels
for each row execute function private.touch_updated_at();
create trigger crm_conversations_touch_updated_at before update on app.crm_conversations
for each row execute function private.touch_updated_at();
create trigger campaigns_touch_updated_at before update on app.campaigns
for each row execute function private.touch_updated_at();
create trigger campaign_recipients_touch_updated_at before update on app.campaign_recipients
for each row execute function private.touch_updated_at();

alter table app.crm_contacts enable row level security;
alter table app.crm_contacts force row level security;
alter table app.crm_contact_channels enable row level security;
alter table app.crm_contact_channels force row level security;
alter table app.crm_conversations enable row level security;
alter table app.crm_conversations force row level security;
alter table app.crm_messages enable row level security;
alter table app.crm_messages force row level security;
alter table app.crm_contact_consents enable row level security;
alter table app.crm_contact_consents force row level security;
alter table app.campaigns enable row level security;
alter table app.campaigns force row level security;
alter table app.campaign_recipients enable row level security;
alter table app.campaign_recipients force row level security;

revoke all on app.crm_contacts, app.crm_contact_channels, app.crm_conversations,
  app.crm_messages, app.crm_contact_consents, app.campaigns, app.campaign_recipients
  from public, anon, authenticated;
grant all on app.crm_contacts, app.crm_contact_channels, app.crm_conversations,
  app.crm_messages, app.crm_contact_consents, app.campaigns, app.campaign_recipients
  to service_role;

comment on table app.crm_messages is 'Conteúdo de conversa minimizado. Acesso somente por rotas operacionais autorizadas e service_role.';
comment on table app.crm_contact_consents is 'Evidência de consentimento por finalidade; exigida antes de qualquer campanha de marketing.';
comment on table app.campaign_recipients is 'Snapshot idempotente de destinatários. Não deve ser recriado após aprovação sem uma nova campanha.';

commit;
