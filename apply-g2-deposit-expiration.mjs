import { readFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.');
}

const migrationPath = 'supabase/migrations/20260817000000_g2_expire_due_deposits.sql';
const query = readFileSync(migrationPath, 'utf8');
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
    `A aplicação de ${migrationPath} retornou HTTP ${response.status}: ${responseText.slice(0, 500)}`
  );
}

console.log(`Aplicada: ${migrationPath}`);
