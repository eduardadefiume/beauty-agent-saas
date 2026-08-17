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

// Os quatro primeiros padrões são os originais. Os demais foram acrescentados
// depois que `.project-config.json` — que continha senha de banco TiDB,
// JWT_SECRET, duas chaves de API e um token git — passou pelo guardrail sem ser
// detectado: nenhum dos padrões antigos cobria DSN com senha nem chave opaca.
const secretPatterns = [
  /sb_secret_[A-Za-z0-9_-]{10,}/,
  /service_role\s*[:=]\s*["']?[^\s"']{10,}/i,
  /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/,
  /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/,

  // DSN com credencial embutida: postgres://, mysql://, redis://, mongodb://...
  // Exige usuário E senha para não acusar `postgres://localhost:5432/db`.
  /\b[a-z][a-z0-9+.-]*:\/\/[^\s:/@"']+:[^\s:/@"']+@[^\s/"']+/i,

  // Segredo atribuído a uma chave cujo nome denuncia o conteúdo.
  // Deliberadamente SEM a flag /i e exigindo valor literal entre aspas: com /i o
  // padrão casava com identificadores comuns de código (`password = ...`,
  // `verifyTokenSecret = Deno.env.get(...)`), e sem as aspas casava com
  // referências a variáveis de ambiente, que não são segredo.
  // Valor precisa ter 16+ caracteres, o que descarta placeholders curtos e
  // atribuições vazias de arquivos .env.example.
  /\b[A-Z][A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_TOKEN|API_KEY|APIKEY)[A-Z0-9_]*["']?\s*[:=]\s*["'](?!SUBSTITUA|REPLACE|CHANGEME|YOUR_)[A-Za-z0-9_\-+./]{16,}["']/,

  // Token de artefato do Manus/Cloudflare, no formato art_v2_...
  /\bart_v2_[A-Za-z0-9_]{8,}/,

  // Token pessoal do GitHub.
  /\bgh[pousr]_[A-Za-z0-9]{20,}/,
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
