import { readFileSync } from 'node:fs';

const files = [
  'scripts/backup/Backup.Common.psm1',
  'scripts/backup/Initialize-ExternalBackup.ps1',
  'scripts/backup/Invoke-DatabaseBackup.ps1',
  'scripts/backup/Invoke-GitBackup.ps1',
  'scripts/backup/Invoke-IndependentBackup.ps1',
  'scripts/backup/Test-BackupArchive.ps1',
];

const joined = files.map((file) => readFileSync(file, 'utf8')).join('\n');
const failures = [];

for (const file of files) {
  const content = readFileSync(file, 'utf8');
  if (!content.includes('Set-StrictMode -Version Latest')) {
    failures.push(`${file}: Set-StrictMode ausente`);
  }
  if (!content.includes("$ErrorActionPreference = 'Stop'")) {
    failures.push(`${file}: ErrorActionPreference ausente`);
  }
}

const forbidden = [
  /postgres(?:ql)?:\/\/[^:\s]+:[^@\s]+@/i,
  /sb_secret_[A-Za-z0-9_-]{10,}/,
  /service_role\s*[:=]\s*["']?[^\s"']{10,}/i,
  /-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----/,
];

if (forbidden.some((pattern) => pattern.test(joined))) {
  failures.push('kit: possível segredo ou chave privada versionada');
}

for (const required of [
  "StartsWith('E:\\'",
  'Export-Clixml',
  'Assert-ConnectionMatchesProjectRef',
  "'--format=custom'",
  "'--no-owner'",
  "'--no-privileges'",
  'Invoke-AgeEncryption',
  'Get-FileHash',
  "'git bundle verify'",
]) {
  if (!joined.includes(required)) {
    failures.push(`kit: proteção obrigatória ausente: ${required}`);
  }
}

if (failures.length > 0) {
  process.stderr.write(`${failures.join('\n')}\n`);
  process.exit(1);
}

process.stdout.write(
  'Kit de backup aprovado na validação estática; execução Windows ainda pendente.\n'
);
