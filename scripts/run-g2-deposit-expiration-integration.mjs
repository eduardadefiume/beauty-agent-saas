import { readFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.');
}

const testPath = 'supabase/tests/g2_deposit_expiration_integration.sql';
const query = readFileSync(testPath, 'utf8');
const response = await fetch(`https://api.supabase.com/v1/projects/${projectRef}/database/query`, {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({ query, read_only: false }),
});

const responseText = await response.text();
if (response.status !== 201) {
  throw new Error(
    `A execução de ${testPath} retornou HTTP ${response.status}: ${responseText.slice(0, 500)}`
  );
}

let payload;
try {
  payload = JSON.parse(responseText);
} catch {
  throw new Error('A API administrativa retornou um corpo não JSON para o teste de integração.');
}

const rows = Array.isArray(payload) ? payload : payload.result;
if (
  !Array.isArray(rows) ||
  !rows.some((row) => row.result === 'G2_DEPOSIT_EXPIRATION_INTEGRATION_OK')
) {
  throw new Error(`Sentinela de integração ausente: ${JSON.stringify(payload).slice(0, 500)}`);
}

console.log(JSON.stringify({ test: testPath, result: 'passed' }, null, 2));
