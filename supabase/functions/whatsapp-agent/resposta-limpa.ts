// O MODELO DEVOLVEU A PROPRIA MARCACAO DENTRO DO TEXTO.
//
// 14/09, duas vezes no mesmo dia. A pergunta que o agente mandou para a dona
// chegou ao painel dela com a marcacao de chamada de ferramenta escrita dentro
// do campo: a tag de fechamento no lugar da pergunta, e o texto real vazando
// para o campo seguinte. A dona respondeu uma delas assim mesmo, lendo o
// pedaco que sobrou.
//
// Nao da para consertar isso no prompt: nao e comportamento, e formato. O
// modelo montou a chamada errada, e nenhuma instrucao em portugues impede
// isso de acontecer de novo.
//
// O QUE ESTA EM JOGO, e nao e o painel feio. Se a mesma quebra cair em
// `messages`, o salao manda marcacao de XML para uma cliente no WhatsApp. Uma
// vez basta para a pessoa entender que do outro lado tem uma maquina -- e mal
// configurada.
//
// Entao: campo com marcacao dentro e resposta invalida. Nao sai, nao e
// gravada, e o turno volta ao modelo uma vez pedindo a chamada limpa. Se
// insistir, a conversa vai para uma pessoa; melhor calado que quebrado.

const PEDACOS = [
  '<\\/?\\s*antml',
  '<\\s*parameter\\b',
  '<\\/\\s*parameter\\s*>',
  '<\\s*function_calls\\b',
  '<\\s*invoke\\b',
  '<\\/\\s*invoke\\s*>',
];

/** A marcacao de chamada de ferramenta, montada por pedacos de proposito. */
const MARCACAO = new RegExp(PEDACOS.join('|'), 'i');

/** O texto carrega marcacao de ferramenta onde deveria haver linguagem. */
export function temMarcacao(texto: unknown): boolean {
  return typeof texto === 'string' && MARCACAO.test(texto);
}

type CamposDaDecisao = {
  messages?: unknown;
  ownerQuestion?: unknown;
  contextSummary?: unknown;
  reason?: unknown;
};

/**
 * Quais campos da decisao vieram sujos. Vazio quer dizer decisao boa.
 *
 * `messages` e o campo mais grave: e o unico que sai para a cliente.
 */
export function camposCorrompidos(decisao: CamposDaDecisao | null | undefined): string[] {
  if (!decisao) return [];
  const sujos: string[] = [];

  const mensagens = Array.isArray(decisao.messages) ? decisao.messages : [];
  if (mensagens.some((m) => temMarcacao(m))) sujos.push('messages');

  for (const campo of ['ownerQuestion', 'contextSummary', 'reason'] as const) {
    if (temMarcacao(decisao[campo])) sujos.push(campo);
  }
  return sujos;
}
