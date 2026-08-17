import { readFileSync } from 'node:fs';

const projectRef = process.env.SUPABASE_PROJECT_REF;
const accessToken = process.env.SUPABASE_ACCESS_TOKEN;

if (!projectRef || !accessToken) {
  throw new Error('SUPABASE_PROJECT_REF e SUPABASE_ACCESS_TOKEN são obrigatórios.');
}

const migrationPaths = [
  'supabase/migrations/20260816000000_g2_add_pending_signal_status.sql',
  'supabase/migrations/20260816001000_g2_appointment_deposit.sql',
];

async function executeMigration(migrationPath) {
  const query = readFileSync(migrationPath, 'utf8');
  const response = await fetch(
    `https://api.supabase.com/v1/projects/${projectRef}/database/query`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query, read_only: false }),
    }
  );

  const responseText = await response.text();
  if (response.status !== 201) {
    throw new Error(
      `A aplicação de ${migrationPath} retornou HTTP ${response.status}: ${responseText.slice(0, 500)}`
    );
  }

  console.log(`Aplicada: ${migrationPath}`);
}

for (const migrationPath of migrationPaths) {
  await executeMigration(migrationPath);
}
