// O DONO RESPONDE "SIM" AO COMPROVANTE.
//
// 01/10, pedido da Duda: a cliente manda o comprovante, o Eddy pergunta ao
// dono "caiu?", ele responde "sim" e o horário é confirmado. O "sim" curto,
// logo depois do aviso, não passa pelo modelo: dinheiro e agenda não dependem
// de interpretação, e um "sim" é a resposta mais ambígua que existe para um
// modelo que tem 20 assuntos abertos com o dono.
//
// Só vale quando a ÚLTIMA coisa que o Eddy disse foi o aviso do sinal (💰 ou
// ⏰) e o dono respondeu curto. Qualquer outra coisa vai para o modelo, que
// tem a ferramenta confirmar_sinal.

export type RespostaAoSinal = { pagou: boolean; referencia: string };

const sem = (t: string) => t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim();

const NAO =
  /^(n|nao|nao caiu|nao chegou|nao entrou|nao recebi|nao apareceu|ainda nao|ainda nao caiu|nada|nada ainda|nao veio|❌)\b/;
const SIM =
  /^(s|sim|si+m+|sim sim|caiu|ja caiu|caiu sim|entrou|ja entrou|chegou|recebi|recebido|pagou|ela pagou|pago|confirmado|confirma|pode confirmar|confirmar|certo|ok|okay|beleza|isso|👍|✅)\b/;

export function respostaAoSinal(
  levaDoDono: string,
  ultimaDoEddy: string,
  pendentes: number
): RespostaAoSinal | null {
  if (pendentes < 1) return null;
  if (!/^\s*(💰|⏰)/u.test(ultimaDoEddy ?? '')) return null;
  const t = sem(levaDoDono ?? '').replace(/[.!,]+$/g, '');
  if (t === '' || t.length > 60 || t.includes('?')) return null;
  const codigo = (t.match(/#?\s?s\s?(\d{4})\b/) ?? [])[1];
  const resto = t.replace(/#?\s?s\s?\d{4}\b/, '').trim();
  if (NAO.test(resto)) return { pagou: false, referencia: codigo ? `S${codigo}` : '' };
  if (SIM.test(resto) || /^[👍✅]/u.test(levaDoDono.trim())) {
    // "sim, mas a Bia ainda não" mistura dois assuntos: deixa para o modelo.
    if (/\b(mas|porem|so que|menos)\b/.test(resto)) return null;
    return { pagou: true, referencia: codigo ? `S${codigo}` : '' };
  }
  return null;
}
