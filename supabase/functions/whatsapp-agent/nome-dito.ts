// O NOME QUE ELA JÁ DISSE.
//
// 30/09, DEV: "Oi, sou a Rê. Queria corte com escova dia 10 depois das 15h"
// -> "Oi, Rê! Tudo bem?" ... "Qual o seu nome?". O prompt já mandava reler
// antes de perguntar; o modelo cumprimentou pelo nome e perguntou o nome.
// O código lê o nome dito com todas as letras e anota antes do modelo.

const APRESENTACAO =
  /(?:^|[\s,.!])(?:[Ss]ou\s+(?:a|o)|[Aa]qui\s+(?:é|e)\s+(?:a|o)|[Mm]eu\s+nome\s+(?:é|e)|[Mm]e\s+chamo|[Pp]ode\s+me\s+chamar\s+de)\s+([A-ZÀ-Ý][a-zà-ÿ]+(?:\s+[A-ZÀ-Ý][a-zà-ÿ]+)?)/;

// "Sou a cliente", "sou a mãe da", "sou a mesma" -- não é nome.
const NAO_E_NOME = new Set([
  'Cliente',
  'Mãe',
  'Mae',
  'Filha',
  'Irmã',
  'Mesma',
  'Mesmo',
  'Dona',
  'Noiva',
]);

export function nomeDito(falasDela: string[]): string | null {
  for (let i = falasDela.length - 1; i >= 0; i--) {
    const m = String(falasDela[i] ?? '').match(APRESENTACAO);
    if (!m) continue;
    const dito = m[1];
    if (!dito) continue;
    const primeiro = dito.split(/\s+/)[0] ?? '';
    if (NAO_E_NOME.has(primeiro)) continue;
    return dito.trim();
  }
  return null;
}
