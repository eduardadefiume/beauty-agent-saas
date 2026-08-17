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
      throw new Error(`${path} não retornou ${expectedSentinel}: ${responseText.slice(0, 1000)}`);
    }
  }
}

async function querySingleResult(query) {
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
    throw new Error(`Pré-condição retornou HTTP ${response.status}: ${responseText.slice(0, 1000)}`);
  }
  const responseBody = JSON.parse(responseText);
  const rows = Array.isArray(responseBody) ? responseBody : responseBody.result ?? [];
  return rows[0]?.result;
}

const precondition = await querySingleResult(`
  select case
    when to_regclass('app.whatsapp_channels') is null then 'BLOCKED_G3_BASE_MISSING'
    when to_regclass('app.whatsapp_webhook_events') is null then 'APPLY'
    else 'SKIP'
  end as result;
`);

if (precondition === 'APPLY') {
  await executeSql({
    path: 'supabase/migrations/20260817130000_g3_webhook_event_inbox.sql',
    readOnly: false,
  });
  console.log('Migration G3.2 aplicada.');
} else if (precondition === 'SKIP') {
  console.log('Migration G3.2 já aplicada; nenhuma DDL será repetida.');
} else {
  throw new Error(`Pré-condição G3.2 inválida: ${precondition ?? 'sem resultado'}`);
}

await executeSql({
  path: 'supabase/tests/g3_webhook_event_inbox_integration.sql',
  readOnly: false,
  expectedSentinel: 'G3_WEBHOOK_EVENT_INBOX_INTEGRATION_OK',
});

console.log('G3.2 migration e integração reversível concluídas com evidência explícita.');
