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

// O MODELO ESCAPOU O PROPRIO JSON, E O ESCAPE FOI PARA A TELA DA CLIENTE.
//
// 16/09, 16:24, no numero de verdade. A cliente leu isto:
//
//   "Luzes é uma família também, Eduarda: pode ser mechas, que
//    clareiam mais os fios, ou morena iluminada, que mantém o fundo
//    escuro e ilumina só em fios finos e no contorno."
//
// No banco a prova e aritmetica: 194 bytes para 194 caracteres. Texto em
// portugues com acento SEMPRE tem mais bytes que caracteres em UTF-8; quando
// os dois numeros batem, nao sobrou acento nenhum -- eles viraram as seis
// letras `é`. A mensagem de dois minutos antes, na mesma conversa, tinha
// 114 bytes para 112 caracteres: essa estava certa.
//
// A causa e irma da marcacao de ferramenta la em cima: o modelo montou o
// campo escrevendo o escape do JSON DENTRO da string, num turno em que a
// trava do procedimento devolveu a resposta para ele reescrever. Nao e
// comportamento e nao adianta pedir em portugues: e formato.
//
// Aqui NAO se descarta o texto, se decodifica. `é` no meio de uma frase
// em portugues nunca e intencao -- e sempre um "é" que se perdeu no caminho.
// Recusar custaria a resposta inteira; desescapar devolve a frase que o
// modelo quis escrever.

/**
 * `\uXXXX` e `\n` escritos como texto, e nao como escape.
 *
 * So estes dois, e o corte e deliberado. `\t` tambem seria escape de JSON, e
 * desfazer ele quebrava "C:\temp" em "C: emp" -- uma barra invertida no meio
 * de um texto pode ser uma barra invertida de verdade. Estes dois nao: `\u00e9`
 * e `\n` escritos com letra, numa frase em portugues, nunca sao intencao.
 */
const ESCAPE_LITERAL = /\\(u[0-9a-fA-F]{4}|n)/g;

/**
 * O texto com os escapes de JSON desfeitos.
 *
 * So mexe no que e escape de verdade: `é` vira "é", `\n` vira quebra de
 * linha. Uma barra invertida solta, ou seguida de qualquer outra coisa, fica
 * como esta -- nao e papel desta funcao adivinhar.
 */
export function semEscapes(texto: string): string {
  return texto.replace(ESCAPE_LITERAL, (inteiro, corpo: string) => {
    if (corpo === 'n') return '\n';
    const ponto = Number.parseInt(corpo.slice(1), 16);
    // Substituto solitario nao e caractere: sozinho ele vira o losango de
    // interrogacao na tela, que e pior que a barra invertida.
    if (ponto >= 0xd800 && ponto <= 0xdfff) return inteiro;
    return String.fromCodePoint(ponto);
  });
}

/** O texto ainda carrega escape de JSON escrito como letra. */
export function temEscapeLiteral(texto: unknown): boolean {
  return typeof texto === 'string' && new RegExp(ESCAPE_LITERAL.source).test(texto);
}
