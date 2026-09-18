-- G3 corrective migration: tenant-scoped relations and inbound idempotency.
-- This migration is additive and preserves the initial G3 table contract.

alter table app.contacts
  add constraint contacts_tenant_id_id_unique unique (tenant_id, id);

alter table app.conversations
  add constraint conversations_tenant_id_id_unique unique (tenant_id, id);

alter table app.messages
  add constraint messages_tenant_id_id_unique unique (tenant_id, id);

alter table app.conversations
  add constraint conversations_tenant_contact_fkey
  foreign key (tenant_id, contact_id)
  references app.contacts (tenant_id, id)
  on delete cascade;

alter table app.messages
  add constraint messages_tenant_conversation_fkey
  foreign key (tenant_id, conversation_id)
  references app.conversations (tenant_id, id)
  on delete cascade;

alter table app.customer_consents
  add constraint customer_consents_tenant_contact_fkey
  foreign key (tenant_id, contact_id)
  references app.contacts (tenant_id, id)
  on delete cascade;

create unique index messages_tenant_whatsapp_message_id_key
  on app.messages (tenant_id, whatsapp_message_id)
  where whatsapp_message_id is not null;

create index conversations_tenant_last_message_idx
  on app.conversations (tenant_id, last_message_at desc);

create index messages_tenant_conversation_created_idx
  on app.messages (tenant_id, conversation_id, created_at desc);

create trigger whatsapp_channels_touch_updated_at
before update on app.whatsapp_channels
for each row execute function private.touch_updated_at();

create trigger contacts_touch_updated_at
before update on app.contacts
for each row execute function private.touch_updated_at();
