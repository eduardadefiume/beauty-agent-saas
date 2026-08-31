// Confere a formatação exatamente como o Quality gate confere: só os arquivos
// alterados, não o repositório inteiro.
//
// Existe porque `pnpm quality` roda `format:check` no repo todo, e o repo tem
// 143 arquivos antigos fora do padrão. Rodar o gate local, então, falha por
// motivo que o CI não checa -- e o resultado é que ninguém roda. Este script
// faz a mesma pergunta que o CI faz, e por isso a resposta dele vale.
//
// Uso:  node scripts/format-check-changed.mjs [base]
//       base padrão: origin/<branch atual>, ou HEAD~1 se não houver remoto.

import { execFileSync } from 'node:child_process';

const EXTENSOES = /\.(ts|tsx|js|mjs|cjs|json|css|md|ya?ml)$/;

function git(...args) {
  return execFileSync('git', args, { encoding: 'utf8' }).trim();
}

function baseParaComparar() {
  if (process.argv[2]) return process.argv[2];
  const branch = git('rev-parse', '--abbrev-ref', 'HEAD');
  try {
    git('rev-parse', '--verify', `origin/${branch}`);
    return `origin/${branch}`;
  } catch {
    return 'HEAD~1';
  }
}

const base = baseParaComparar();
const alterados = git('diff', '--name-only', '--diff-filter=ACMR', base, 'HEAD')
  .split('\n')
  .filter((linha) => linha.length > 0 && EXTENSOES.test(linha));

if (alterados.length === 0) {
  console.log(`Nenhum arquivo formatável alterado desde ${base}.`);
  process.exit(0);
}

console.log(`Conferindo ${alterados.length} arquivo(s) alterado(s) desde ${base}:`);
for (const arquivo of alterados) console.log(` - ${arquivo}`);

try {
  execFileSync('pnpm', ['exec', 'prettier', '--check', '--ignore-unknown', ...alterados], {
    stdio: 'inherit',
  });
} catch {
  console.error('\nFormatação reprovada. Rode: pnpm exec prettier --write <arquivos acima>');
  process.exit(1);
}
