// A REGRA DE DEVOLUÇÃO DO SINAL, COMO O DONO DISSE.
//
// 02/10, DEV, William-robô configurando do zero: "se desmarcar com menos de
// 24h não devolve" foi gravado como "não devolve" (nunca). A frase diz o
// contrário: com 24h ou mais de aviso, devolve. Um sinal que nunca volta é a
// regra que mais gera briga com cliente -- não pode depender da leitura do
// modelo. O código lê o óbvio e prevalece; na dúvida, devolve null e fica a
// leitura do modelo.

export type DevolucaoDita = { devolve: boolean; ateHoras: number | null };

const sem = (t: string) =>
  ` ${t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ')} `;

const NUM: Record<string, number> = {
  um: 1,
  uma: 1,
  dois: 2,
  duas: 2,
  tres: 3,
  quatro: 4,
  cinco: 5,
  seis: 6,
  sete: 7,
  doze: 12,
  vinte: 20,
  trinta: 30,
};

/** "24h", "48 horas", "2 dias", "um dia", "1 semana" -> horas. */
function horas(trecho: string): number | null {
  const m = trecho.match(
    /\b(\d{1,3}|um|uma|dois|duas|tres|quatro|cinco|seis|sete|doze|vinte|trinta)\s*(h|hs|hrs?|horas?|dias?|semanas?)\b/
  );
  if (!m) return null;
  const quanto = m[1] ?? '';
  const unidade = m[2] ?? '';
  const n = /^\d+$/.test(quanto) ? Number(quanto) : NUM[quanto];
  if (!n) return null;
  if (/^dia/.test(unidade)) return n * 24;
  if (/^semana/.test(unidade)) return n * 24 * 7;
  return n;
}

const DEVOLUCAO =
  /(devolv|devolu|reembols|estorn|volta o (sinal|dinheiro)|perde o sinal|fica com o sinal|nao volta|não volta)/;

// 10/10, PRODUÇÃO, William: "o valor da entrada não SERÁ devolvido" virou
// "devolve com 48h". A negação só era vista colada ("não devolv"), e o "dois
// dias" de OUTRA regra (cobrança integral) entrou na conta. Agora a negação
// aceita até três palavras no meio ("não vai ser devolvido", "não há
// devolução", "sem reembolso") e cada frase é lida sozinha: frases que dizem
// coisas diferentes sobre a devolução deixam a decisão com o modelo.
const NEGADA =
  /\b(?:nao|nunca|sem)\s+(?:[a-z]+\s+){0,3}?(?:devolv|devolu|reembols|estorn)\w*|\b(?:nao volta|perde o sinal|perdeu o sinal|desmarcou perdeu|fica com o sinal)\b/g;
const POSITIVA = /(devolv|devolu|reembols|estorn|volta o (sinal|dinheiro))/;
const MENOS = /\b(menos de|antes de completar|com menos|abaixo de|dentro de|nas ultimas)\b/;

function daFrase(t: string): DevolucaoDita | null {
  if (!DEVOLUCAO.test(t) && !/\b(desmarc|cancel)/.test(t)) return null;
  const negada = new RegExp(NEGADA.source).test(t);
  const positiva = POSITIVA.test(t.replace(NEGADA, ' '));
  const h = horas(t);
  // "com menos de 24h não devolve" / "se desmarcar em cima da hora (menos de 1 dia) perde"
  if (h && negada && MENOS.test(t)) return { devolve: true, ateHoras: h };
  // "devolve se avisar com 48h", "avisando 2 dias antes devolve", "com mais de 24h devolve"
  if (h && positiva && !negada) return { devolve: true, ateHoras: h };
  if (/\bdevolv\w* sempre|\bsempre devolv/.test(t) && !negada)
    return { devolve: true, ateHoras: 0 };
  // "não devolve", "sinal não volta", "não será devolvido", "sem reembolso"
  if (negada && !positiva) return { devolve: false, ateHoras: null };
  return null;
}

export function devolucaoDita(fala: string): DevolucaoDita | null {
  const lidas = sem(fala)
    .split(/[.;!?\n\t]+/)
    .map((f) => daFrase(` ${f.trim()} `))
    .filter((x): x is DevolucaoDita => x !== null);
  if (lidas.length === 0) return null;
  const [primeira] = lidas;
  return lidas.every((x) => x.devolve === primeira!.devolve && x.ateHoras === primeira!.ateHoras)
    ? primeira!
    : null;
}
