import { appendFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.');
}

const query = `
select jsonb_build_object(
  'expirationEventSourceAllowed', exists (
    select 1
      from pg_constraint constraint_catalog
      join pg_class table_catalog on table_catalog.oid = constraint_catalog.conrelid
      join pg_namespace schema_catalog on schema_catalog.oid = table_catalog.relnamespace
     where schema_catalog.nspname = 'app'
       and table_catalog.relname = 'appointment_deposit_events'
       and constraint_catalog.conname = 'appointment_deposit_events_event_source_check'
       and position('SYSTEM_EXPIRATION' in pg_get_constraintdef(constraint_catalog.oid)) > 0
  ),
  'expirationFunctionExists', to_regprocedure('public.schedule_expire_due_deposits(text,integer)') is not null,
  'expirationFunctionUsesLocks', coalesce((
    select position('FOR UPDATE OF D SKIP LOCKED' in upper(pg_get_functiondef(function_catalog.oid))) > 0
       and position('SYSTEM_EXPIRATION' in pg_get_functiondef(function_catalog.oid)) > 0
      from pg_proc function_catalog
      join pg_namespace function_schema on function_schema.oid = function_catalog.pronamespace
     where function_schema.nspname = 'public'
       and function_catalog.proname = 'schedule_expire_due_deposits'
     limit 1
  ), false),
  'serviceRoleCanExecute', has_function_privilege('service_role', 'public.schedule_expire_due_deposits(text,integer)', 'EXECUTE'),
  'anonCannotExecute', not has_function_privilege('anon', 'public.schedule_expire_due_deposits(text,integer)', 'EXECUTE'),
  'authenticatedCannotExecute', not has_function_privilege('authenticated', 'public.schedule_expire_due_deposits(text,integer)', 'EXECUTE')
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
  throw new Error(`A auditoria G2 retornou HTTP ${response.status}: ${responseText.slice(0, 500)}`);
}

const payload = JSON.parse(responseText);
const row = Array.isArray(payload)
  ? payload[0]
  : Array.isArray(payload.result)
    ? payload.result[0]
    : payload;
const evidence = row?.evidence;
const passed = Boolean(
  evidence?.expirationEventSourceAllowed &&
  evidence?.expirationFunctionExists &&
  evidence?.expirationFunctionUsesLocks &&
  evidence?.serviceRoleCanExecute &&
  evidence?.anonCannotExecute &&
  evidence?.authenticatedCannotExecute
);
const safeEvidence = { ...evidence, passed, checkedAtUtc: new Date().toISOString() };

console.log(JSON.stringify(safeEvidence, null, 2));
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `## Auditoria G2 — expiração de sinal\n\n\`\`\`json\n${JSON.stringify(safeEvidence, null, 2)}\n\`\`\`\n`
  );
}
if (!passed) {
  throw new Error('A expiração G2 não atendeu os controles estruturais esperados.');
}
