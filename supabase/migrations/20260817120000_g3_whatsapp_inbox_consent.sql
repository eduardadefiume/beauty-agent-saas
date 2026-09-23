-- ============================================================================
-- G3: WhatsApp Webhook Ingestion, Inbox Projection and LGPD Consent
-- Fase 1: Single tenant per test, strict multi-tenant RLS enforcement.
-- ============================================================================

create table if not exists app.whatsapp_channels (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references app.tenants(id) on delete cascade,
    phone_number_id text not null,
    waba_id text not null,
    access_token_encrypted text not null,
    status text not null default 'ACTIVE',
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    constraint whatsapp_channels_phone_tenant_key unique (tenant_id, phone_number_id)
);

create table if not exists app.contacts (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references app.tenants(id) on delete cascade,
    phone_number text not null,
    full_name text,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    constraint contacts_tenant_phone_key unique (tenant_id, phone_number)
);

create table if not exists app.conversations (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references app.tenants(id) on delete cascade,
    contact_id uuid not null references app.contacts(id) on delete cascade,
    status text not null default 'OPEN',
    last_message_at timestamptz not null default statement_timestamp(),
    created_at timestamptz not null default statement_timestamp(),
    constraint conversations_tenant_contact_key unique (tenant_id, contact_id)
);

create table if not exists app.messages (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references app.tenants(id) on delete cascade,
    conversation_id uuid not null references app.conversations(id) on delete cascade,
    direction text not null check (direction in ('INBOUND', 'OUTBOUND')),
    sender_type text not null check (sender_type in ('CLIENT', 'AGENT', 'HUMAN_OWNER')),
    body text not null,
    whatsapp_message_id text,
    status text not null default 'RECEIVED',
    created_at timestamptz not null default statement_timestamp()
);

create table if not exists app.customer_consents (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references app.tenants(id) on delete cascade,
    contact_id uuid not null references app.contacts(id) on delete cascade,
    channel text not null default 'WHATSAPP',
    purpose text not null default 'SCHEDULING_REMINDERS_AND_NOTICES',
    status text not null default 'GRANTED' check (status in ('GRANTED', 'REVOKED')),
    granted_at timestamptz not null default statement_timestamp(),
    source text not null default 'INBOUND_OPT_IN',
    constraint customer_consents_unique unique (tenant_id, contact_id, channel, purpose)
);

-- Enable RLS and Force RLS
alter table app.whatsapp_channels enable row level security;
alter table app.whatsapp_channels force row level security;

alter table app.contacts enable row level security;
alter table app.contacts force row level security;

alter table app.conversations enable row level security;
alter table app.conversations force row level security;

alter table app.messages enable row level security;
alter table app.messages force row level security;

alter table app.customer_consents enable row level security;
alter table app.customer_consents force row level security;

-- Grants strictly to service_role for transactional database execution
revoke all on app.whatsapp_channels from public, anon, authenticated;
grant all on app.whatsapp_channels to service_role;

revoke all on app.contacts from public, anon, authenticated;
grant all on app.contacts to service_role;

revoke all on app.conversations from public, anon, authenticated;
grant all on app.conversations to service_role;

revoke all on app.messages from public, anon, authenticated;
grant all on app.messages to service_role;

revoke all on app.customer_consents from public, anon, authenticated;
grant all on app.customer_consents to service_role;
