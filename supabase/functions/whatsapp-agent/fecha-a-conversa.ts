// A CLIENTE PERGUNTOU E FICOU SEM SABER O QUE FAZER DEPOIS.
//
// Conversa real de 14/09. A cliente mandou duas perguntas na mesma leva:
//
//   "Você acha que essa cor vai combinar comigo?"
//   "Acha que da certo fazer no meu cabelo?"
//
// O agente respondeu UMA ("isso quem confirma é o teste de mechas") e parou. A
// outra ficou no ar, e a conversa morreu ali: sem horário, sem pergunta, sem
// nada para a cliente responder. A ficha dela estava COMPLETA -- não faltava
// informação nenhuma para oferecer horário.
//
// Duas regras de prompt já mandavam o contrário (`TODA_PERGUNTA_TEM_RESPOSTA` e
// o desenho que manda fechar com horário quando `missing` está vazio). As duas
// falharam caladas, que é como regra de prompt falha.
//
// Esta trava não julga se a resposta ficou boa. Ela pergunta uma coisa
// mecânica: a cliente perguntou alguma coisa, e a resposta devolveu ALGUM
// próximo passo? Próximo passo é uma pergunta de volta, um horário concreto, ou
// um agendamento fechado. Resposta que não tem nenhum dos três deixa a cliente
// olhando para a tela sem saber o que fazer -- e cliente sem próximo passo é
// cliente que some.
//
// Quando dispara, NÃO descarta a resposta: devolve o turno ao modelo uma vez,
// dizendo o que faltou. Perder a resposta inteira seria pior que mandá-la
// incompleta.

/** Um horário concreto: "8h", "14:30", "quinta 04/09". */
const HORARIO = /\b\d{1,2}\s*h(\s*\d{2})?\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}\/\d{1,2}\b/i;

// "Oi, boa tarde! Tudo bem?" tem interrogação e não é próximo passo nenhum.
//
// A primeira versão desta trava contava qualquer "?" como pergunta, e o
// cumprimento a desarmou na primeira conversa de verdade: o agente abriu com
// "Oi, boa tarde! Tudo bem?", respondeu o preço, parou -- e passou batido,
// porque tecnicamente havia uma interrogação na leva. Cumprimento é educação,
// não é pergunta: não devolve nada para a cliente decidir.
//
// A borda é `(?![\p{L}\p{N}])` e não `\b` de propósito: em JavaScript o `\b` é
// ASCII, então "Olá" termina numa letra que ele não reconhece como letra e a
// borda simplesmente não existe. Português sem acento não é opção aqui.
const SO_CUMPRIMENTO =
  /^(oi|ol[áa]|bom dia|boa tarde|boa noite|tudo bem|tudo bom|como vai|e a[íi])(?![\p{L}\p{N}])[^?]*\?+$/iu;

/** A mensagem faz uma pergunta de verdade, que não seja o cumprimento. */
function perguntaDeVerdade(texto: string): boolean {
  const limpo = texto.trim();
  return limpo.includes('?') && !SO_CUMPRIMENTO.test(limpo);
}

type Fala = { text?: unknown; direction?: unknown };

/**
 * A última leva da cliente: as mensagens INBOUND seguidas que fecham o
 * histórico. É o que ela acabou de dizer, antes de qualquer resposta.
 */
export function ultimaLevaDaCliente(volatil: unknown): string[] {
  const historico = (volatil as { history?: unknown } | null)?.history;
  if (!Array.isArray(historico)) return [];

  const leva: string[] = [];
  for (let i = historico.length - 1; i >= 0; i--) {
    const fala = historico[i] as Fala;
    if (fala?.direction !== 'INBOUND') break;
    if (typeof fala.text === 'string' && fala.text.trim().length > 0) {
      leva.unshift(fala.text);
    }
  }
  return leva;
}

/** Quantas perguntas ela fez na última leva. */
export function perguntasNaLeva(leva: string[]): number {
  return leva.reduce((total, fala) => total + (fala.match(/\?/g)?.length ?? 0), 0);
}

/**
 * true quando a cliente perguntou alguma coisa e a resposta não devolveu
 * próximo passo nenhum.
 *
 * `ofereceuHorario` vem do turno, não do texto: horário que o agente tem na
 * mão porque consultou a agenda, ou agendamento que ele acabou de fechar.
 */
export function respostaSemProximoPasso(
  textos: string[],
  leva: string[],
  ofereceuHorario: boolean
): boolean {
  if (perguntasNaLeva(leva) === 0) return false;
  if (ofereceuHorario) return false;
  return !textos.some((t) => perguntaDeVerdade(t) || HORARIO.test(t));
}

// A PERGUNTA DE DINHEIRO QUE NAO PODE MORRER.
//
// 14/09, conversa real. A cliente mandou duas coisas na mesma leva:
//
//   "Terça não consigo, tem sexta depois do almoço?"
//   "Esse valor você dividi?"
//
// O agente respondeu a primeira com um horario e simplesmente seguiu. A
// segunda ficou sem resposta -- e a trava de cima nao pegou, porque havia
// horario na resposta: do ponto de vista dela, a conversa tinha proximo passo.
//
// Condicao comercial e a pior pergunta para deixar morrer, e a regra do prompt
// ja diz isso com todas as letras: forma de pagamento, parcelamento, cartao,
// sinal e desconto NAO se inventam -- ou estao escritos nos dados do salao, ou
// e pergunta para a dona. Ficar calado nao e uma das opcoes: a cliente que
// pergunta se parcela esta decidindo se cabe no bolso dela.
//
// Por isso esta trava e por assunto, e nao por contagem de interrogacao:
// quando ela toca em dinheiro e nem a resposta nem a pergunta para a dona
// tocam no assunto, o turno volta.

const ASSUNTO_COMERCIAL =
  /(parcel|dividi|divid[ae]|cart[ãa]o|pix|desconto|sinal|entrada|d[ée]bito|cr[ée]dito|boleto|forma de pagamento|meio de pagamento|pagamento|pagar|maquininha)/i;

/**
 * true quando a cliente perguntou de condicao comercial e ninguem tratou:
 * nem a resposta, nem a pergunta enviada a dona.
 */
export function condicaoComercialIgnorada(
  textos: string[],
  leva: string[],
  perguntaParaDona: string
): boolean {
  const ela = leva.filter((f) => f.includes('?'));
  if (!ela.some((f) => ASSUNTO_COMERCIAL.test(f))) return false;
  if (ASSUNTO_COMERCIAL.test(perguntaParaDona ?? '')) return false;
  return !textos.some((t) => ASSUNTO_COMERCIAL.test(t));
}
