begin;

insert into app.tenants (id, display_name, slug)
values
  ('f3000000-0000-0000-0000-000000000001', 'G3 Tenant Alpha', 'g3-tenant-alpha'),
  ('f3000000-0000-0000-0000-000000000002', 'G3 Tenant Beta', 'g3-tenant-beta');

insert into app.whatsapp_channels (
  id, tenant_id, phone_number_id, waba_id, access_token_encrypted
) values (
  'f3100000-0000-0000-0000-000000000001',
  'f3000000-0000-0000-0000-000000000001',
  'test-phone-number-id-alpha',
  'test-waba-alpha',
  'test-only-encrypted-token-reference'
);

insert into app.contacts (id, tenant_id, phone_number, full_name)
values
  ('f3200000-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-000000000001', '+5516999990001', 'Contato Alpha'),
  ('f3200000-0000-0000-0000-000000000002', 'f3000000-0000-0000-0000-000000000002', '+5516999990002', 'Contato Beta');

insert into app.conversations (id, tenant_id, contact_id, status)
values
  ('f3300000-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-000000000001', 'f3200000-0000-0000-0000-000000000001', 'OPEN'),
  ('f3300000-0000-0000-0000-000000000002', 'f3000000-0000-0000-0000-000000000002', 'f3200000-0000-0000-0000-000000000002', 'OPEN');

insert into app.messages (
  id, tenant_id, conversation_id, direction, sender_type, body, whatsapp_message_id
) values (
  'f3400000-0000-0000-0000-000000000001',
  'f3000000-0000-0000-0000-000000000001',
  'f3300000-0000-0000-0000-000000000001',
  'INBOUND', 'CLIENT', 'Mensagem de teste Alpha', 'wamid.g3-alpha-001'
);

insert into app.customer_consents (
  id, tenant_id, contact_id, channel, purpose, status, source
) values (
  'f3500000-0000-0000-0000-000000000001',
  'f3000000-0000-0000-0000-000000000001',
  'f3200000-0000-0000-0000-000000000001',
  'WHATSAPP', 'SCHEDULING_REMINDERS_AND_NOTICES', 'GRANTED', 'INTEGRATION_TEST'
);

do $$
declare
  g3_table_count integer;
begin
  select count(*) into g3_table_count
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'app'
     and c.relname in ('whatsapp_channels', 'contacts', 'conversations', 'messages', 'customer_consents')
     and c.relkind = 'r';

  if g3_table_count <> 5 then
    raise exception 'G3_TABLE_COUNT_INVALID_%', g3_table_count;
  end if;

  if exists (
    select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app'
       and c.relname in ('whatsapp_channels', 'contacts', 'conversations', 'messages', 'customer_consents')
       and (not c.relrowsecurity or not c.relforcerowsecurity)
  ) then
    raise exception 'G3_RLS_NOT_ENABLED_AND_FORCED';
  end if;

  if has_table_privilege('anon', 'app.contacts', 'SELECT')
    or has_table_privilege('authenticated', 'app.contacts', 'SELECT')
    or not has_table_privilege('service_role', 'app.contacts', 'SELECT, INSERT, UPDATE, DELETE') then
    raise exception 'G3_TABLE_GRANTS_INVALID';
  end if;

  begin
    insert into app.conversations (id, tenant_id, contact_id, status)
    values (
      'f3300000-0000-0000-0000-000000000003',
      'f3000000-0000-0000-0000-000000000002',
      'f3200000-0000-0000-0000-000000000001',
      'OPEN'
    );
    raise exception 'CROSS_TENANT_CONVERSATION_WAS_ALLOWED';
  exception when foreign_key_violation then
    null;
  end;

  begin
    insert into app.messages (
      id, tenant_id, conversation_id, direction, sender_type, body, whatsapp_message_id
    ) values (
      'f3400000-0000-0000-0000-000000000002',
      'f3000000-0000-0000-0000-000000000002',
      'f3300000-0000-0000-0000-000000000001',
      'INBOUND', 'CLIENT', 'Tentativa cruzada', 'wamid.g3-cross-tenant'
    );
    raise exception 'CROSS_TENANT_MESSAGE_WAS_ALLOWED';
  exception when foreign_key_violation then
    null;
  end;

  begin
    insert into app.customer_consents (
      id, tenant_id, contact_id, channel, purpose, status, source
    ) values (
      'f3500000-0000-0000-0000-000000000002',
      'f3000000-0000-0000-0000-000000000002',
      'f3200000-0000-0000-0000-000000000001',
      'WHATSAPP', 'SCHEDULING_REMINDERS_AND_NOTICES', 'GRANTED', 'INTEGRATION_TEST'
    );
    raise exception 'CROSS_TENANT_CONSENT_WAS_ALLOWED';
  exception when foreign_key_violation then
    null;
  end;

  begin
    insert into app.messages (
      id, tenant_id, conversation_id, direction, sender_type, body, whatsapp_message_id
    ) values (
      'f3400000-0000-0000-0000-000000000003',
      'f3000000-0000-0000-0000-000000000001',
      'f3300000-0000-0000-0000-000000000001',
      'INBOUND', 'CLIENT', 'Duplicata', 'wamid.g3-alpha-001'
    );
    raise exception 'WHATSAPP_MESSAGE_DEDUPLICATION_FAILED';
  exception when unique_violation then
    null;
  end;
end;
$$;

rollback;

select 'G3_WHATSAPP_INBOX_CONSENT_INTEGRATION_OK' as result;
