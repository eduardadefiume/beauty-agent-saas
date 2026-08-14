import { appendFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.')
}

const query = `
with expected_tables(table_name) as (
  values
    ('service_technical_profiles'),
    ('service_technical_requirements'),
    ('service_step_product_requirements')
), expected_columns(column_name) as (
  values
    ('technical_category'),
    ('minimum_duration_minutes'),
    ('maximum_duration_minutes'),
    ('professional_confirmation_required'),
    ('product_record_required')
)
select jsonb_build_object(
  'tables', (
    select jsonb_agg(jsonb_build_object(
      'table', expected_tables.table_name,
      'exists', catalog_table.oid is not null,
      'rls', coalesce(catalog_table.relrowsecurity, false),
      'forceRls', coalesce(catalog_table.relforcerowsecurity, false),
      'anonSelect', case when catalog_table.oid is null then null else has_table_privilege('anon', catalog_table.oid, 'select') end,
      'authenticatedSelect', case when catalog_table.oid is null then null else has_table_privilege('authenticated', catalog_table.oid, 'select') end,
      'serviceRoleSelect', case when catalog_table.oid is null then null else has_table_privilege('service_role', catalog_table.oid, 'select') end
    ) order by expected_tables.table_name)
    from expected_tables
    left join pg_namespace catalog_schema on catalog_schema.nspname = 'app'
    left join pg_class catalog_table on catalog_table.relnamespace = catalog_schema.oid
      and catalog_table.relname = expected_tables.table_name
      and catalog_table.relkind = 'r'
  ),
  'columns', (
    select jsonb_agg(jsonb_build_object(
      'column', expected_columns.column_name,
      'exists', information_schema_columns.column_name is not null,
      'notNull', coalesce(information_schema_columns.is_nullable = 'NO', false)
    ) order by expected_columns.column_name)
    from expected_columns
    left join information_schema.columns information_schema_columns
      on information_schema_columns.table_schema = 'app'
      and information_schema_columns.table_name = 'service_steps'
      and information_schema_columns.column_name = expected_columns.column_name
  ),
  'durationConstraint', exists (
    select 1
    from pg_constraint constraint_definition
    join pg_class constrained_table on constrained_table.oid = constraint_definition.conrelid
    join pg_namespace constrained_schema on constrained_schema.oid = constrained_table.relnamespace
    where constrained_schema.nspname = 'app'
      and constrained_table.relname = 'service_steps'
      and constraint_definition.conname = 'service_steps_duration_window_check'
      and constraint_definition.contype = 'c'
  ),
  'draftProtectionTriggerEnabled', coalesce((
    select catalog_trigger.tgenabled = 'O'
    from pg_trigger catalog_trigger
    join pg_class trigger_table on trigger_table.oid = catalog_trigger.tgrelid
    join pg_namespace trigger_schema on trigger_schema.oid = trigger_table.relnamespace
    where trigger_schema.nspname = 'app'
      and trigger_table.relname = 'service_steps'
      and catalog_trigger.tgname = 'app_service_steps_draft_open'
      and not catalog_trigger.tgisinternal
    limit 1
  ), false),
  'snapshotContractHasTechnicalProfile', coalesce((
    select position('technicalProfile' in pg_get_functiondef(function_definition.oid)) > 0
    from pg_proc function_definition
    join pg_namespace function_schema on function_schema.oid = function_definition.pronamespace
    where function_schema.nspname = 'private'
      and function_definition.proname = 'build_configuration_snapshot'
    limit 1
  ), false),
  'replaceContractHasCatalogWrites', coalesce((
    select position('service_technical_profiles' in pg_get_functiondef(function_definition.oid)) > 0
       and position('service_step_product_requirements' in pg_get_functiondef(function_definition.oid)) > 0
    from pg_proc function_definition
    join pg_namespace function_schema on function_schema.oid = function_definition.pronamespace
    where function_schema.nspname = 'public'
      and function_definition.proname = 'site_replace_configuration'
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
  throw new Error(`A consulta de validação retornou HTTP ${response.status}: ${responseText.slice(0, 500)}`)
}

let payload;
try {
  payload = JSON.parse(responseText);
} catch {
  throw new Error('A API administrativa retornou um corpo não JSON para a consulta de validação.')
}

const row = Array.isArray(payload) ? payload[0] : Array.isArray(payload.result) ? payload.result[0] : payload;
const evidence = row?.evidence;
if (!evidence || typeof evidence !== 'object') {
  throw new Error(`Formato inesperado da resposta de validação: ${JSON.stringify(payload).slice(0, 500)}`)
}

const tablesPass = evidence.tables?.every(table =>
  table.exists && table.rls && table.forceRls && table.anonSelect === false &&
  table.authenticatedSelect === false && table.serviceRoleSelect === true,
);
const columnsPass = evidence.columns?.every(column => column.exists && column.notNull);
const passed = Boolean(
  tablesPass &&
  columnsPass &&
  evidence.durationConstraint &&
  evidence.draftProtectionTriggerEnabled &&
  evidence.snapshotContractHasTechnicalProfile &&
  evidence.replaceContractHasCatalogWrites,
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
    `## Validação do catálogo técnico\n\n\`\`\`json\n${JSON.stringify(safeEvidence, null, 2)}\n\`\`\`\n`,
  );
}

if (!passed) {
  throw new Error('O catálogo técnico não atendeu todos os controles estruturais esperados. Consulte a evidência acima.')
}
