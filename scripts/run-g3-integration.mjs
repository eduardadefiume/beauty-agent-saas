import { readFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.');
}

async function executeSql({ path, readOnly, expectedSentinel }) {
  const query = readFileSync(path, 'utf8');
  const response = await fetch(`https://api.supabase.com/v1/projects/${projectRef}/database/query`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ query, read_only: readOnly }),
  });

  const responseText = await response.text();
  if (response.status !== 201) {
    throw new Error(`${path} retornou HTTP ${response.status}: ${responseText.slice(0, 1000)}`);
  }

  let responseBody;
  try {
    responseBody = JSON.parse(responseText);
  } catch {
    throw new Error(`${path} retornou resposta não JSON: ${responseText.slice(0, 1000)}`);
  }

  if (expectedSentinel) {
    const rows = Array.isArray(responseBody) ? responseBody : responseBody.result ?? [];
    if (!rows.some((row) => row.result === expectedSentinel)) {
      throw new Error(`${path} não retornou o sentinela ${expectedSentinel}. Resposta: ${responseText.slice(0, 1000)}`);
    }
  }

  console.log(`Concluído: ${path}`);
}

async function queryResult(query) {
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
    throw new Error(`Consulta de pré-condição retornou HTTP ${response.status}: ${responseText.slice(0, 1000)}`);
  }
  const responseBody = JSON.parse(responseText);
  const rows = Array.isArray(responseBody) ? responseBody : responseBody.result ?? [];
  return rows[0]?.result;
}

const migrations = [
  {
    path: 'supabase/migrations/20260817120000_g3_whatsapp_inbox_consent.sql',
    precondition: `select case when to_regclass('app.whatsapp_channels') is null then 'APPLY' else 'SKIP' end as result;`,
  },
  {
    path: 'supabase/migrations/20260817121000_g3_inbox_integrity.sql',
    precondition: `select case when exists (
      select 1 from pg_constraint where conname = 'messages_tenant_conversation_fkey'
    ) then 'SKIP' else 'APPLY' end as result;`,
  },
];

for (const migration of migrations) {
  const action = await queryResult(migration.precondition);
  if (action === 'APPLY') {
    await executeSql({ path: migration.path, readOnly: false });
  } else if (action === 'SKIP') {
    console.log(`Já aplicada: ${migration.path}`);
  } else {
    throw new Error(`Pré-condição inválida para ${migration.path}: ${action ?? 'sem resultado'}`);
  }
}

await executeSql({
  path: 'supabase/tests/g3_whatsapp_inbox_consent_integration.sql',
  readOnly: false,
  expectedSentinel: 'G3_WHATSAPP_INBOX_CONSENT_INTEGRATION_OK',
});

console.log('G3 migration e integração concluídas com evidência explícita.');
