import { appendFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.');
}

const query = `
with expected_tables(table_name) as (
  values
    ('whatsapp_channels'),
    ('contacts'),
    ('conversations'),
    ('messages'),
    ('customer_consents')
), expected_tenant_columns(table_name) as (
  values
    ('whatsapp_channels'),
    ('contacts'),
    ('conversations'),
    ('messages'),
    ('customer_consents')
), expected_constraints(constraint_name) as (
  values
    ('contacts_tenant_phone_key'),
    ('contacts_tenant_id_id_unique'),
    ('conversations_tenant_contact_key'),
    ('conversations_tenant_id_id_unique'),
    ('conversations_tenant_contact_fkey'),
    ('messages_tenant_id_id_unique'),
    ('messages_tenant_conversation_fkey'),
    ('customer_consents_unique'),
    ('customer_consents_tenant_contact_fkey')
), expected_triggers(trigger_name) as (
  values
    ('whatsapp_channels_touch_updated_at'),
    ('contacts_touch_updated_at')
)
select jsonb_build_object(
  'tables', (
    select jsonb_agg(jsonb_build_object(
      'table', expected_tables.table_name,
      'exists', table_catalog.oid is not null,
      'rls', coalesce(table_catalog.relrowsecurity, false),
      'forceRls', coalesce(table_catalog.relforcerowsecurity, false),
      'anonSelect', case when table_catalog.oid is null then null else has_table_privilege('anon', table_catalog.oid, 'select') end,
      'authenticatedSelect', case when table_catalog.oid is null then null else has_table_privilege('authenticated', table_catalog.oid, 'select') end,
      'serviceRoleSelect', case when table_catalog.oid is null then null else has_table_privilege('service_role', table_catalog.oid, 'select') end,
      'serviceRoleInsert', case when table_catalog.oid is null then null else has_table_privilege('service_role', table_catalog.oid, 'insert') end,
      'serviceRoleUpdate', case when table_catalog.oid is null then null else has_table_privilege('service_role', table_catalog.oid, 'update') end,
      'serviceRoleDelete', case when table_catalog.oid is null then null else has_table_privilege('service_role', table_catalog.oid, 'delete') end
    ) order by expected_tables.table_name)
    from expected_tables
    left join pg_namespace schema_catalog on schema_catalog.nspname = 'app'
    left join pg_class table_catalog on table_catalog.relnamespace = schema_catalog.oid
      and table_catalog.relname = expected_tables.table_name
      and table_catalog.relkind = 'r'
  ),
  'tenantColumns', (
    select jsonb_agg(jsonb_build_object(
      'table', expected_tenant_columns.table_name,
      'exists', information_schema_columns.column_name is not null,
      'notNull', coalesce(information_schema_columns.is_nullable = 'NO', false)
    ) order by expected_tenant_columns.table_name)
    from expected_tenant_columns
    left join information_schema.columns information_schema_columns
      on information_schema_columns.table_schema = 'app'
      and information_schema_columns.table_name = expected_tenant_columns.table_name
      and information_schema_columns.column_name = 'tenant_id'
  ),
  'constraints', (
    select jsonb_agg(jsonb_build_object(
      'constraint', expected_constraints.constraint_name,
      'exists', constraint_catalog.oid is not null,
      'type', constraint_catalog.contype
    ) order by expected_constraints.constraint_name)
    from expected_constraints
    left join pg_constraint constraint_catalog on constraint_catalog.conname = expected_constraints.constraint_name
    left join pg_namespace schema_catalog on schema_catalog.oid = constraint_catalog.connamespace
      and schema_catalog.nspname = 'app'
  ),
  'deduplicationIndex', coalesce((
    select jsonb_build_object(
      'exists', true,
      'unique', index_catalog.indisunique,
      'partial', index_catalog.indpred is not null,
      'definition', pg_get_indexdef(index_catalog.indexrelid)
    )
    from pg_index index_catalog
    join pg_class index_relation on index_relation.oid = index_catalog.indexrelid
    join pg_class table_catalog on table_catalog.oid = index_catalog.indrelid
    join pg_namespace schema_catalog on schema_catalog.oid = table_catalog.relnamespace
    where schema_catalog.nspname = 'app'
      and table_catalog.relname = 'messages'
      and index_relation.relname = 'messages_tenant_whatsapp_message_id_key'
  ), jsonb_build_object('exists', false)),
  'touchTriggers', (
    select jsonb_agg(jsonb_build_object(
      'trigger', expected_triggers.trigger_name,
      'enabled', coalesce(trigger_catalog.tgenabled = 'O', false)
    ) order by expected_triggers.trigger_name)
    from expected_triggers
    left join pg_trigger trigger_catalog on trigger_catalog.tgname = expected_triggers.trigger_name
      and not trigger_catalog.tgisinternal
  )
) as evidence;
`;

const response = await fetch(`https://api.supabase.com/v1/projects/${projectRef}/database/query`, {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({ query, read_only: true }),
});

const responseText = await response.text();
if (response.status !== 201) {
  throw new Error(`A auditoria G3 retornou HTTP ${response.status}: ${responseText.slice(0, 500)}`);
}

let payload;
try {
  payload = JSON.parse(responseText);
} catch {
  throw new Error('A API administrativa retornou um corpo não JSON para a auditoria G3.');
}

const row = Array.isArray(payload)
  ? payload[0]
  : Array.isArray(payload.result)
    ? payload.result[0]
    : payload;
const evidence = row?.evidence;
if (!evidence || typeof evidence !== 'object') {
  throw new Error(`Formato inesperado da evidência G3: ${JSON.stringify(payload).slice(0, 500)}`);
}

const tablesPass = evidence.tables?.every(
  (table) =>
    table.exists &&
    table.rls &&
    table.forceRls &&
    table.anonSelect === false &&
    table.authenticatedSelect === false &&
    table.serviceRoleSelect === true &&
    table.serviceRoleInsert === true &&
    table.serviceRoleUpdate === true &&
    table.serviceRoleDelete === true
);
const tenantColumnsPass = evidence.tenantColumns?.every((column) => column.exists && column.notNull);
const constraintsPass = evidence.constraints?.every((constraint) => constraint.exists);
const deduplicationPass = Boolean(
  evidence.deduplicationIndex?.exists &&
    evidence.deduplicationIndex?.unique &&
    evidence.deduplicationIndex?.partial &&
    evidence.deduplicationIndex?.definition?.includes('(tenant_id, whatsapp_message_id)') &&
    evidence.deduplicationIndex?.definition?.includes('whatsapp_message_id IS NOT NULL')
);
const touchTriggersPass = evidence.touchTriggers?.every((trigger) => trigger.enabled);
const passed = Boolean(tablesPass && tenantColumnsPass && constraintsPass && deduplicationPass && touchTriggersPass);

const safeEvidence = {
  ...evidence,
  passed,
  checkedAtUtc: new Date().toISOString(),
};

console.log(JSON.stringify(safeEvidence, null, 2));

if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `## Auditoria estrutural G3 — Inbox WhatsApp e consentimento\n\n\`\`\`json\n${JSON.stringify(safeEvidence, null, 2)}\n\`\`\`\n`
  );
}

if (!passed) {
  throw new Error('O G3 não atendeu todos os controles estruturais esperados. Consulte a evidência acima.');
}
