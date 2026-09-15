// O PROCEDIMENTO É ESCOLHA DELA. O AGENTE NÃO SUPÕE, NÃO AFIRMA E NÃO ESCOLHE.
//
// 14/09, à noite. Uma cliente nova escreveu "gostaria de marcar um
// procedimento". O agente perguntou o nome, pediu foto do cabelo, perguntou de
// química, de progressiva, de formol -- oito mensagens de interrogatório -- e
// terminou com "Tenho amanhã, terça, às 13h, pode ser?".
//
// Horário de QUE? No banco: ele consultou a agenda de "Mechas morena
// iluminada". A cliente nunca disse isso.
//
// 15/09 de manhã, a mesma conversa, com a primeira versão desta trava já no ar:
//
//   08:32  "Tenho hoje às 13h para sua coloração, pode ser?"
//   08:33  "A coloração está R$ 160,00."
//   08:39  cliente: "Não é coloração"
//   08:41  "Então me conta, o que você quer fazer no cabelo?"
//   08:42  cliente: "Eu gostaria de fazer uma progressiva"
//   08:43  "Certo, trocando então para progressiva com formol, R$ 200,00."
//
// Três buracos, e nenhum deles é o que a primeira versão tapava:
//
// 1. "sua coloração" -- ela NUNCA disse coloração. A trava só olhava se o nome
//    do serviço tinha aparecido na conversa, e quem tinha feito ele aparecer
//    era o próprio agente. A conta fechava consigo mesma.
//
// 2. Ele AFIRMOU o procedimento ("a coloração está R$ 160") em vez de
//    perguntar. Cliente lê afirmação como decisão tomada.
//
// 3. Ela disse "uma progressiva" e ele escolheu sozinho "Progressiva com
//    formol" -- entre CINCO progressivas do catálogo (3D, 4D, japonesa, com
//    formol, sem formol), todas R$ 200. Escolheu justo a com formol, para
//    quem tinha acabado de contar que fez formol há um mês.
//
// Então o que esta trava verifica agora não é "o nome apareceu", é:
//   - a CLIENTE escolheu, com as palavras dela ou com um sim a uma pergunta;
//   - o agente não está afirmando como fechado o que ela não escolheu;
//   - o que ela pediu não casa com mais de um serviço do catálogo.

/** Uma fala da conversa, na ordem em que aconteceu. */
export type Fala = { direction?: unknown; text?: unknown };

/** Um horário concreto na mensagem: "13h", "14:30", "quinta 18/09". */
const HORARIO = /\b\d{1,2}\s*h(\s*\d{2})?\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}\/\d{1,2}\b/i;

/** Qualquer valor em dinheiro. */
const DINHEIRO = /R\$\s*[\d.,]+|\b[\d.,]+\s*(reais|real)\b/i;

// Conectivo, palavra genérica de catálogo e verbo de pedido. Nada aqui
// identifica um serviço: "fazer" casaria com qualquer frase, e "teste" casaria
// com a conversa sobre teste de mecha.
const IRRELEVANTES = new Set([
  'de', 'da', 'do', 'com', 'sem', 'para', 'por', 'e', 'a', 'o', 'as', 'os',
  'no', 'na', 'em', 'um', 'uma', 'teste', 'dia', 'mesmo', 'semana',
  'quero', 'queria', 'gostaria', 'fazer', 'marcar', 'agendar', 'procedimento',
  'cabelo', 'adicional', 'junto',
]);

// O que a cliente diz quando está PEDINDO, e não contando a história dela.
// "já fiz progressiva há um mês" não é pedido; "queria fazer progressiva" é.
const INTENCAO =
  /\b(quero|queria|gostaria|gostava|desejo|pretendo|preciso|vou fazer|posso fazer|pode fazer|marcar|agendar|marca|agenda|fazer)\b/i;

// Resposta afirmativa a uma pergunta do agente. O `^` é de propósito: "sim"
// no meio de uma frase longa é outra coisa.
const AFIRMACAO =
  /^[\s\p{P}]*(sim|isso|é isso|isso mesmo|exato|exatamente|perfeito|pode ser|pode sim|quero|quero sim|claro|com certeza|aham|uhum|ok|okay|blz|beleza|vamos|bora|fechado|positivo|👍|👌|✅)(?![\p{L}\p{N}])/iu;

// O agente nomeando o serviço não basta: "essa química tinha formol?" nomeia
// "Progressiva com formol" e é pergunta sobre o passado dela. Um "sim" só vale
// como escolha se o que ele perguntou era sobre FAZER o procedimento.
const PROPOSTA =
  /\b(quer|queria|quiser|gostaria|deseja|vamos|seria|posso|marco|marcar|agendar|reservar|confirma|confirmo|fechado|fica|custa|tenho)\b/i;

const NEGACAO =
  /(^|\W)n[ãa]o\s+([ée]|eh|quero|queria|vai ser|era|vou|pode|seria)(?![\p{L}\p{N}])|nada disso|de jeito nenhum|(^|\W)n[ãa]o[\s\p{P}]*$/iu;

function normalizar(texto: string): string {
  return texto
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase();
}

/**
 * As palavras que identificam um serviço. "Mechas morena iluminada" vira
 * ['mechas','morena','iluminada'].
 */
export function palavrasDoServico(nome: string): string[] {
  return normalizar(nome)
    .split(/[^a-z0-9]+/)
    .filter((p) => p.length > 3 && !IRRELEVANTES.has(p));
}

/**
 * A raiz da palavra, sem a vogal de genero e numero.
 *
 * 15/09: a cliente escreveu "iluminado" e o catalogo diz "Mechas morena
 * iluminada". Comparacao exata nao casou, a trava ficou cega, e o agente
 * respondeu sobre o servico errado. "iluminada" -> "iluminad" casa com
 * "iluminado" e com "iluminados"; palavra curta fica inteira, senao sobra
 * raiz demais e tudo casa com tudo.
 */
function raiz(palavra: string): string {
  return palavra.length > 4 ? palavra.slice(0, -1) : palavra;
}

/** O texto nomeia este serviço -- ainda que por uma palavra só. */
export function mencionaServico(texto: string, nomeDoServico: string): boolean {
  const palavras = palavrasDoServico(nomeDoServico);
  if (palavras.length === 0) return false;
  const tudo = normalizar(texto);
  return palavras.some((p) => tudo.includes(raiz(p)));
}

/** Alguma destas falas nomeia o serviço. */
export function servicoFoiDito(textos: string[], nomeDoServico: string): boolean {
  const palavras = palavrasDoServico(nomeDoServico);
  if (palavras.length === 0) return true;
  return mencionaServico(textos.join(' '), nomeDoServico);
}

/** Alguma fala já disse um valor. */
export function precoFoiDito(textos: string[]): boolean {
  return textos.some((t) => DINHEIRO.test(t));
}

/** A resposta oferece um horário concreto. */
export function ofereceHorario(textos: string[]): boolean {
  return textos.some((t) => HORARIO.test(t));
}

/** A conversa inteira, na ordem, as duas vozes. */
export function falasDaConversa(volatil: unknown): Fala[] {
  const historico = (volatil as { history?: unknown } | null)?.history;
  if (!Array.isArray(historico)) return [];
  return historico.filter(
    (f) => typeof (f as Fala)?.text === 'string' && (f as { text: string }).text.trim().length > 0
  ) as Fala[];
}

/** O que o agente já falou nesta conversa, na ordem. */
export function falasDoAgente(volatil: unknown): string[] {
  return falasDaConversa(volatil)
    .filter((f) => f.direction === 'OUTBOUND')
    .map((f) => f.text as string);
}

/** O que a cliente já escreveu nesta conversa, na ordem. */
export function falasDaCliente(volatil: unknown): string[] {
  return falasDaConversa(volatil)
    .filter((f) => f.direction === 'INBOUND')
    .map((f) => f.text as string);
}

/**
 * O que a CLIENTE fez com este serviço, do ponto de vista dela:
 *
 *   ESCOLHEU  -- pediu com as palavras dela, ou disse sim quando ele perguntou
 *   MENCIONOU -- falou o nome, mas contando história ou perguntando preço
 *   NEGOU     -- disse que não é isso
 *   NUNCA     -- nunca escreveu nada parecido; quem disse foi o agente
 *
 * A ordem importa, e é ela que separa "já fiz progressiva há um mês" de
 * "queria fazer progressiva": pedido e história usam as mesmas palavras, o que
 * muda é o verbo -- e um "sim" só vale como escolha se a pergunta logo antes
 * era sobre esse serviço.
 */
export type Escolha = 'ESCOLHEU' | 'MENCIONOU' | 'NEGOU' | 'NUNCA';

export function escolhaDaCliente(historico: Fala[], nomeDoServico: string | null): Escolha {
  if (!nomeDoServico || palavrasDoServico(nomeDoServico).length === 0) return 'NUNCA';

  let escolha: Escolha = 'NUNCA';
  let agenteAcabouDeNomear = false;

  for (const fala of historico) {
    const texto = String(fala.text ?? '');

    if (fala.direction === 'OUTBOUND') {
      agenteAcabouDeNomear = mencionaServico(texto, nomeDoServico) && PROPOSTA.test(texto);
      continue;
    }

    const menciona = mencionaServico(texto, nomeDoServico);
    const nega = NEGACAO.test(texto);

    if (nega && (menciona || agenteAcabouDeNomear)) escolha = 'NEGOU';
    else if (menciona && INTENCAO.test(texto)) escolha = 'ESCOLHEU';
    else if (agenteAcabouDeNomear && AFIRMACAO.test(texto)) escolha = 'ESCOLHEU';
    else if (menciona && escolha !== 'ESCOLHEU') escolha = 'MENCIONOU';

    agenteAcabouDeNomear = false;
  }

  return escolha;
}

/** Quantas falas dela entram no pedido, além da que tem o verbo. */
const FALAS_DO_PEDIDO = 3;

/**
 * O que a cliente PEDIU, com as palavras dela.
 *
 * Nao cabe numa mensagem so, e o caso de 15/09 mostra por que: ela escreveu
 * "Qual o valor da progressiva?" e, na mensagem seguinte, "Eu estava querendo
 * fazer um iluminado tambem, qual eu faco primeiro?". Lendo so a ultima, o
 * pedido e "iluminado"; lendo as duas, sao DOIS servicos e uma pergunta de
 * ordem entre quimicas.
 *
 * Isto alarga so a deteccao de AMBIGUIDADE, e de proposito: o pior que
 * acontece com uma mensagem antiga entrando aqui e o agente PERGUNTAR qual
 * dos servicos ela quer. Perguntar demais custa uma mensagem; supor errado
 * custa um cabelo. Quem decide se ela ESCOLHEU continua sendo
 * `escolhaDaCliente`, que le mensagem por mensagem.
 */
function pedidoRecente(historico: Fala[]): string | null {
  const dela: string[] = [];
  let achouVerbo = false;

  for (let i = historico.length - 1; i >= 0 && dela.length < FALAS_DO_PEDIDO + 1; i--) {
    const fala = historico[i];
    if (!fala || fala.direction !== 'INBOUND') continue;
    const texto = String(fala.text ?? '');
    // "Nao e coloracao" e o contrario de um pedido. Com a janela mais larga,
    // sem esta linha o servico que ela ACABOU de recusar voltava para a lista.
    if (NEGACAO.test(texto) && !INTENCAO.test(texto)) continue;
    dela.unshift(texto);
    if (INTENCAO.test(texto)) achouVerbo = true;
  }

  return achouVerbo ? dela.join(' ') : null;
}

/**
 * Quantas palavras do nome do serviço estão no pedido dela. `null` quer dizer
 * que este serviço está DESCARTADO: ela disse "sem formol" e o nome é "com
 * formol" (ou o contrário). É o par que separa serviços irmãos no catálogo, e
 * confundir os dois é justo o erro caro -- formol em cima de formol.
 */
function pontuacao(pedido: string, nomeDoServico: string): number | null {
  const texto = normalizar(pedido);
  const nome = normalizar(nomeDoServico);

  for (const [, preposicao, palavra] of nome.matchAll(/\b(com|sem)\s+([a-z0-9]+)/g)) {
    const oposta = preposicao === 'com' ? 'sem' : 'com';
    if (new RegExp(`\\b${oposta}\\s+${palavra}\\b`).test(texto)) return null;
  }

  return palavrasDoServico(nomeDoServico).filter((p) => texto.includes(raiz(p))).length;
}

/**
 * Os serviços do catálogo que cabem no que ela pediu.
 *
 * Um só: ela escolheu, ainda que sem dizer o nome inteiro. Mais de um: ela
 * pediu "uma progressiva" e o salão tem cinco -- quem escolhe é ela, e a
 * pergunta é obrigatória. Nenhum: o pedido não fala de serviço nenhum.
 */
export function servicosQueCabem(historico: Fala[], catalogo: string[]): string[] {
  const pedido = pedidoRecente(historico);
  if (!pedido) return [];

  let melhor = 0;
  const pontos = new Map<string, number>();
  for (const nome of catalogo) {
    if (typeof nome !== 'string' || nome.trim().length === 0) continue;
    const ponto = pontuacao(pedido, nome);
    if (ponto == null || ponto === 0) continue;
    // Nomes repetidos no catálogo (rascunho e publicado) são o mesmo serviço.
    if (!pontos.has(nome)) pontos.set(nome, ponto);
    if (ponto > melhor) melhor = ponto;
  }

  return [...pontos.entries()]
    .filter(([, ponto]) => ponto === melhor)
    .map(([nome]) => nome)
    .sort();
}

/** A resposta afirma o serviço como fechado, em vez de perguntar. */
// "São cinco progressivas: 3D, 4D, japonesa, com e sem formol. Qual você
// quer?" nomeia o serviço numa frase sem interrogação -- e é exatamente o que
// se quer que ele faça. O que manda na mensagem é a pergunta de escolha.
const PERGUNTA_DE_ESCOLHA = /\b(qual|quais|prefere|voc[êe] quer|pode ser|confirma)\b[^?]*\?/i;

export function afirmaServico(textos: string[], nomeDoServico: string): boolean {
  return textos.some((texto) => {
    if (!mencionaServico(texto, nomeDoServico)) return false;
    if (PERGUNTA_DE_ESCOLHA.test(texto)) return false;
    return texto
      .split(/(?<=[.!?…])\s+|\n+/)
      .some((trecho) => mencionaServico(trecho, nomeDoServico) && !trecho.includes('?'));
  });
}

export type Falta = 'PROCEDIMENTO' | 'PRECO' | 'AFIRMOU' | 'IRMAOS';

/**
 * O que falta antes de o agente poder seguir com este serviço.
 *
 * `historico` é a conversa inteira, as duas vozes -- sem a voz dela não dá
 * para saber se ela escolheu. `catalogo` são os nomes dos serviços do salão.
 */
export function travaDoProcedimento(
  textos: string[],
  historico: Fala[],
  nomeDoServico: string | null,
  catalogo: string[] = []
): { falta: Falta | null; opcoes: string[] } {
  const vazio = { falta: null, opcoes: [] as string[] };
  if (textos.length === 0) return vazio;

  const escolha = escolhaDaCliente(historico, nomeDoServico);
  const cabem = servicosQueCabem(historico, catalogo);
  const ambiguo = cabem.length > 1 && (!nomeDoServico || cabem.includes(nomeDoServico));

  // Afirmar um serviço que ela nunca pediu -- ou que ela já disse que não é --
  // é a frase que fecha a decisão no lugar dela.
  if (nomeDoServico && (escolha === 'NUNCA' || escolha === 'NEGOU') && afirmaServico(textos, nomeDoServico)) {
    return { falta: 'AFIRMOU', opcoes: cabem };
  }

  // Ela pediu "uma progressiva" e o salão tem cinco. Escolher por ela é
  // exatamente o erro de 15/09.
  if (ambiguo && nomeDoServico && (afirmaServico(textos, nomeDoServico) || ofereceHorario(textos))) {
    return { falta: 'IRMAOS', opcoes: cabem };
  }

  if (!ofereceHorario(textos)) return vazio;

  if (escolha !== 'ESCOLHEU') return { falta: 'PROCEDIMENTO', opcoes: cabem };

  const ditoPeloAgente = [
    ...historico.filter((f) => f.direction === 'OUTBOUND').map((f) => String(f.text ?? '')),
    ...textos,
  ];
  if (!precoFoiDito(ditoPeloAgente)) return { falta: 'PRECO', opcoes: cabem };

  return vazio;
}
