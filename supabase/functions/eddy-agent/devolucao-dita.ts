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
  const n = /^\d+$/.test(m[1]) ? Number(m[1]) : NUM[m[1]];
  if (!n) return null;
  if (/^dia/.test(m[2])) return n * 24;
  if (/^semana/.test(m[2])) return n * 24 * 7;
  return n;
}

const DEVOLUCAO =
  /(devolv|devolu|reembols|estorn|volta o (sinal|dinheiro)|perde o sinal|fica com o sinal|nao volta|não volta)/;

export function devolucaoDita(fala: string): DevolucaoDita | null {
  const t = sem(fala);
  if (!DEVOLUCAO.test(t) && !/\b(desmarc|cancel)/.test(t)) return null;
  const h = horas(t);
  // "com menos de 24h não devolve" / "se desmarcar em cima da hora (menos de 1 dia) perde"
  if (
    h &&
    /\b(menos de|antes de completar|com menos|abaixo de|dentro de|nas ultimas)\b/.test(t) &&
    /\b(nao devolv|nao tem devolu|perde|fica com|nao volta|nao reembols|nao estorn)/.test(t)
  ) {
    return { devolve: true, ateHoras: h };
  }
  // "devolve se avisar com 48h", "avisando 2 dias antes devolve", "com mais de 24h devolve"
  if (
    h &&
    /\b(devolv|reembols|estorn|volta)/.test(t) &&
    !/\bnao devolv|\bnao reembols|\bnao estorn|\bnao volta/.test(t)
  ) {
    return { devolve: true, ateHoras: h };
  }
  // "não devolve", "sinal não volta", "não tem devolução", "desmarcou perdeu"
  if (
    /\b(nao devolv|nao tem devolu|sem devolu|nao volta|nao reembols|nunca devolv|perde o sinal|perdeu o sinal|desmarcou perdeu)/.test(
      t
    )
  ) {
    return { devolve: false, ateHoras: null };
  }
  if (/\bdevolv\w* sempre|\bsempre devolv/.test(t)) return { devolve: true, ateHoras: 0 };
  return null;
}
