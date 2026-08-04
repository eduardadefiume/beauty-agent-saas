import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';

const ignoredDirectories = new Set(['.git', '.next', '.turbo', 'coverage', 'dist', 'node_modules']);

function listWorkspaceFiles(directory = '.') {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);

    if (entry.isDirectory()) {
      return ignoredDirectories.has(entry.name) ? [] : listWorkspaceFiles(path);
    }

    return [relative('.', path).replaceAll('\\', '/')];
  });
}

function listTrackedFiles() {
  try {
    return execFileSync('git', ['ls-files', '-z'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
      .split('\0')
      .filter(Boolean);
  } catch {
    return listWorkspaceFiles();
  }
}

const trackedFiles = listTrackedFiles();

const ruleFiles = trackedFiles.filter(
  (path) =>
    path.startsWith('packages/domain/src/') || path.startsWith('packages/scheduling-engine/src/')
);

const textFiles = trackedFiles.filter(
  (path) =>
    !path.endsWith('pnpm-lock.yaml') &&
    /(?:\.(?:ts|tsx|js|mjs|json|ya?ml|toml|sql)|\.env\.example)$/.test(path)
);

const failures = [];
const pilotNamePattern = /\b(?:William|Jack)\b/i;
const secretPatterns = [
  /sb_secret_[A-Za-z0-9_-]{10,}/,
  /service_role\s*[:=]\s*["']?[^\s"']{10,}/i,
  /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/,
  /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/,
];

for (const path of ruleFiles) {
  if (pilotNamePattern.test(readFileSync(path, 'utf8'))) {
    failures.push(`${path}: nome de piloto encontrado em regra de produção`);
  }
}

for (const path of textFiles) {
  const content = readFileSync(path, 'utf8');
  if (secretPatterns.some((pattern) => pattern.test(content))) {
    failures.push(`${path}: possível segredo versionado`);
  }
}

if (failures.length > 0) {
  process.stderr.write(`${failures.join('\n')}\n`);
  process.exit(1);
}

process.stdout.write(
  'Guardrails aprovados: sem regra por nome de piloto e sem segredo detectado.\n'
);
