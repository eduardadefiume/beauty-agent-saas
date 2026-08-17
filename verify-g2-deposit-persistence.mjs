import { appendFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.');
}

const query = `
with expected_tables(table_name) as (
  values
    ('service_deposit_policies'),
    ('appointment_deposits'),
    ('appointment_deposit_events')
), expected_columns(table_name, column_name) as (
  values
    ('appointment_deposits', 'tenant_id'),
    ('appointment_deposits', 'appointment_id'),
    ('appointment_deposits', 'amount_cents'),
    ('appointment_deposits', 'status'),
    ('appointment_deposit_events', 'tenant_id'),
    ('appointment_deposit_events', 'external_event_ref'),
    ('appointment_deposit_events', 'correlation_id')
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
      'serviceRoleSelect', case when table_catalog.oid is null then null else has_table_privilege('service_role', table_catalog.oid, 'select') end
    ) order by expected_tables.table_name)
    from expected_tables
    left join pg_namespace schema_catalog on schema_catalog.nspname = 'app'
    left join pg_class table_catalog on table_catalog.relnamespace = schema_catalog.oid
      and table_catalog.relname = expected_tables.table_name
      and table_catalog.relkind = 'r'
  ),
  'columns', (
    select jsonb_agg(jsonb_build_object(
      'table', expected_columns.table_name,
      'column', expected_columns.column_name,
      'exists', information_schema_columns.column_name is not null,
      'notNull', coalesce(information_schema_columns.is_nullable = 'NO', false)
    ) order by expected_columns.table_name, expected_columns.column_name)
    from expected_columns
    left join information_schema.columns information_schema_columns
      on information_schema_columns.table_schema = 'app'
      and information_schema_columns.table_name = expected_columns.table_name
      and information_schema_columns.column_name = expected_columns.column_name
  ),
  'pendingSignalEnum', exists (
    select 1
    from pg_enum enum_value
    join pg_type enum_type on enum_type.oid = enum_value.enumtypid
    join pg_namespace enum_schema on enum_schema.oid = enum_type.typnamespace
    where enum_schema.nspname = 'app'
      and enum_type.typname = 'appointment_status'
      and enum_value.enumlabel = 'PENDING_SIGNAL'
  ),
  'depositPolicyEnum', (
    select coalesce(jsonb_agg(enum_value.enumlabel order by enum_value.enumsortorder), '[]'::jsonb)
    from pg_enum enum_value
    join pg_type enum_type on enum_type.oid = enum_value.enumtypid
    join pg_namespace enum_schema on enum_schema.oid = enum_type.typnamespace
    where enum_schema.nspname = 'app'
      and enum_type.typname = 'deposit_policy_kind'
  ),
  'depositStatusEnum', (
    select coalesce(jsonb_agg(enum_value.enumlabel order by enum_value.enumsortorder), '[]'::jsonb)
    from pg_enum enum_value
    join pg_type enum_type on enum_type.oid = enum_value.enumtypid
    join pg_namespace enum_schema on enum_schema.oid = enum_type.typnamespace
    where enum_schema.nspname = 'app'
      and enum_type.typname = 'deposit_status'
  ),
  'eventIdempotencyConstraint', exists (
    select 1
    from pg_constraint constraint_catalog
    join pg_class table_catalog on table_catalog.oid = constraint_catalog.conrelid
    join pg_namespace schema_catalog on schema_catalog.oid = table_catalog.relnamespace
    where schema_catalog.nspname = 'app'
      and table_catalog.relname = 'appointment_deposit_events'
      and constraint_catalog.conname = 'appointment_deposit_events_idempotency'
      and constraint_catalog.contype = 'u'
  ),
  'snapshotImmutabilityTrigger', coalesce((
    select trigger_catalog.tgenabled = 'O'
    from pg_trigger trigger_catalog
    join pg_class table_catalog on table_catalog.oid = trigger_catalog.tgrelid
    join pg_namespace schema_catalog on schema_catalog.oid = table_catalog.relnamespace
    where schema_catalog.nspname = 'app'
      and table_catalog.relname = 'appointment_deposits'
      and trigger_catalog.tgname = 'appointment_deposits_preserve_snapshot'
      and not trigger_catalog.tgisinternal
    limit 1
  ), false),
  'confirmHoldHasPendingSignal', coalesce((
    select position('PENDING_SIGNAL' in pg_get_functiondef(function_catalog.oid)) > 0
    from pg_proc function_catalog
    join pg_namespace function_schema on function_schema.oid = function_catalog.pronamespace
    where function_schema.nspname = 'public'
      and function_catalog.proname = 'schedule_confirm_hold'
    limit 1
  ), false),
  'registerConfirmationHasManualRoleGate', coalesce((
    select position('MANUAL_VERIFIED' in pg_get_functiondef(function_catalog.oid)) > 0
      and position('OWNER' in pg_get_functiondef(function_catalog.oid)) > 0
      and position('ADMIN' in pg_get_functiondef(function_catalog.oid)) > 0
    from pg_proc function_catalog
    join pg_namespace function_schema on function_schema.oid = function_catalog.pronamespace
    where function_schema.nspname = 'public'
      and function_catalog.proname = 'schedule_register_deposit_confirmation'
    limit 1
  ), false),
  'cancelAppointmentCancelsPendingDeposit', coalesce((
    select position('SYSTEM_CANCELLATION' in pg_get_functiondef(function_catalog.oid)) > 0
      and position('PENDING_SIGNAL' in pg_get_functiondef(function_catalog.oid)) > 0
    from pg_proc function_catalog
    join pg_namespace function_schema on function_schema.oid = function_catalog.pronamespace
    where function_schema.nspname = 'public'
      and function_catalog.proname = 'schedule_cancel_appointment'
    limit 1
  ), false)
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
  throw new Error(
    `A consulta de validação retornou HTTP ${response.status}: ${responseText.slice(0, 500)}`
  );
}

let payload;
try {
  payload = JSON.parse(responseText);
} catch {
  throw new Error('A API administrativa retornou um corpo não JSON para a consulta de validação.');
}

const row = Array.isArray(payload)
  ? payload[0]
  : Array.isArray(payload.result)
    ? payload.result[0]
    : payload;
const evidence = row?.evidence;
if (!evidence || typeof evidence !== 'object') {
  throw new Error(
    `Formato inesperado da resposta de validação: ${JSON.stringify(payload).slice(0, 500)}`
  );
}
const expectedPolicyKinds = ['NONE', 'FIXED_CENTS', 'PERCENT'];
const expectedStatuses = ['NOT_REQUIRED', 'PENDING', 'CONFIRMED', 'EXPIRED', 'WAIVED', 'CANCELLED'];
const tablesPass = evidence.tables?.every(
  (table) =>
    table.exists &&
    table.rls &&
    table.forceRls &&
    table.anonSelect === false &&
    table.authenticatedSelect === false &&
    table.serviceRoleSelect === true
);
const columnsPass = evidence.columns?.every((column) => column.exists && column.notNull);
const policyEnumPass =
  JSON.stringify(evidence.depositPolicyEnum) === JSON.stringify(expectedPolicyKinds);
const statusEnumPass =
  JSON.stringify(evidence.depositStatusEnum) === JSON.stringify(expectedStatuses);
const passed = Boolean(
  tablesPass &&
  columnsPass &&
  evidence.pendingSignalEnum &&
  policyEnumPass &&
  statusEnumPass &&
  evidence.eventIdempotencyConstraint &&
  evidence.snapshotImmutabilityTrigger &&
  evidence.confirmHoldHasPendingSignal &&
  evidence.registerConfirmationHasManualRoleGate &&
  evidence.cancelAppointmentCancelsPendingDeposit
);

const safeEvidence = {
  ...evidence,
  passed,
  checkedAtUtc: new Date().toISOString(),
};

console.log(JSON.stringify(safeEvidence, null, 2));

if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `## Validação G2 — persistência de sinal\n\n\`\`\`json\n${JSON.stringify(safeEvidence, null, 2)}\n\`\`\`\n`
  );
}
if (!passed) {
  throw new Error(
    'A persistência G2 de sinal não atendeu todos os controles estruturais esperados. Consulte a evidência acima.'
  );
}
