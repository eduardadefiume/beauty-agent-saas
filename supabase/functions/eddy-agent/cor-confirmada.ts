// A RESPOSTA DE COR TEM QUE TER SAÍDO DA BOCA DELE.
//
// 02/10, DEV, William-robô: ele disse "oxe, já te expliquei no áudio de cor"
// e o Eddy gravou "clareia até 2 níveis", "teste a partir de 3" e "química
// exige teste" -- valores que ele nunca disse. O resultado acabou certo só
// porque ele aceitou o padrão depois. responder_cor só grava se o valor está
// na fala dele, ou se ele aceitou o padrão que o Eddy acabou de mostrar.

const sem = (t: string) =>
  ` ${String(t ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')} `;

const EXTENSO: Record<string, number> = {
  zero: 0,
  um: 1,
  uma: 1,
  dois: 2,
  duas: 2,
  tres: 3,
  quatro: 4,
  cinco: 5,
  seis: 6,
  sete: 7,
  oito: 8,
  nove: 9,
  dez: 10,
  quinze: 15,
  vinte: 20,
  trinta: 30,
  quarenta: 40,
  cinquenta: 50,
  sessenta: 60,
  noventa: 90,
  cem: 100,
};

function numerosDitos(t: string): number[] {
  const n: number[] = [];
  for (const m of t.matchAll(/(\d+(?:[.,]\d+)?)/g)) n.push(Number(m[1].replace(',', '.')));
  for (const [p, v] of Object.entries(EXTENSO)) if (new RegExp(`\\b${p}\\b`).test(t)) n.push(v);
  if (/\bmeia hora\b/.test(t)) n.push(30);
  if (/\b(uma|1) hora\b/.test(t)) n.push(60);
  if (/\b(uma|1) hora e meia\b/.test(t)) n.push(90);
  if (/\bduas horas\b|\b2 ?h(oras)?\b/.test(t)) n.push(120);
  return n;
}

const ACEITA =
  /\b(pode ser|pode|isso( mesmo| ai)?|sim|ok|blz|beleza|fechado|normal|padrao|assim mesmo|ta bom|ta otimo|perfeito|certo|exato|faco assim|desse jeito)\b/;
const NEGA = /\b(nao|nunca|nada|sem|incluso|inclusa|incluido|de graca|gratis)\b/;
const AFIRMA = /\b(sim|sempre|exijo|exige|faco|obrigatorio)\b/;

export function corConfirmada(o: {
  unidade: string;
  valor: number;
  falaDoDono: string;
  ultimaDoEddy: string;
}): boolean {
  const fala = sem(o.falaDoDono);
  const antes = sem(o.ultimaDoEddy);
  // Aceitou o padrão que acabou de ser mostrado.
  if (/padrao/.test(antes) && ACEITA.test(fala)) return true;
  if (o.unidade === 'SIM_NAO') {
    return o.valor ? AFIRMA.test(fala) : NEGA.test(fala);
  }
  if (o.valor === 0 && NEGA.test(fala)) return true;
  return numerosDitos(fala).some((n) => Math.abs(n - o.valor) < 0.001);
}
