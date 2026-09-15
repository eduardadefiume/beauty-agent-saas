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

/** A mesma coisa, para APAGAR: pega a tag inteira, fechada ou nao. */
const PARA_APAGAR = new RegExp('(?:' + PEDACOS.join('|') + ')(?:[^>]*>)?', 'gi');

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

/**
 * O texto sem a marcacao, se sobrar texto.
 *
 * 15/09: tres turnos da mesma conversa cairam aqui, e o pedido de refazer nao
 * limpou nenhum. Apagar o campo inteiro -- que era o que acontecia -- trocava
 * a frase da dona por "resposta do modelo veio quebrada" no painel. Tirar a
 * tag e ficar com o portugues que sobrou e melhor em todos os casos: ou sobra
 * a frase, ou sobra nada e ai sim o campo vai vazio.
 *
 * Isto NAO vale para `messages`: o que sai para a cliente nao se remenda.
 */
export function semMarcacao(texto: unknown): string {
  if (typeof texto !== 'string') return '';
  const limpo = texto
    .replace(PARA_APAGAR, ' ')
    // Tag que ficou aberta no fim do campo: o resto dela nao existe.
    .replace(/<[^>]*$/, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return temMarcacao(limpo) ? '' : limpo;
}
