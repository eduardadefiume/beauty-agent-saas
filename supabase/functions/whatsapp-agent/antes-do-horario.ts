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
//
// 16/09, e este é o buraco embaixo de todos os outros. A conversa inteira, no
// número de verdade:
//
//   15:38  cliente: "Qual o valor da progressiva?"
//   15:39  "A progressiva fica R$ 200,00."
//   15:44  cliente: "Eu estava querendo fazer um iluminado também, qual eu faço primeiro?"
//   15:45  "Progressiva primeiro, Eduarda, não indico as duas químicas no mesmo período."
//   15:45  "Manda uma foto do seu cabelo hoje, como ele está?"
//   10:05  cliente: "Qual o valor da progressiva?"          <- ela PERGUNTOU DE NOVO
//   10:07  "Bom dia, Eduarda! A progressiva fica R$ 200,00."
//   10:07  "Ainda estou esperando aquela foto do seu cabelo hoje, pode me mandar?"
//   10:56  cliente: "Esse valor é com formol ou sem formol?"
//   10:58  "Com formol, Eduarda."                            <- escolheu por ela, de novo
//   10:58  "Ainda estou esperando aquela foto do seu cabelo hoje, pode me mandar?"
//
// A trava acima já estava no ar e não pegou NADA disso. O motivo, no banco:
// `agent_scheduling_focus` para essa conversa tem ZERO linhas. O foco só nasce
// quando o agente consulta a AGENDA -- e ele nunca consultou, porque nunca
// chegou a oferecer horário. Sem foco, `nomeDoServico` chega null aqui, e as
// três primeiras portas desta função exigiam `nomeDoServico` para abrir. A
// quarta (`if (!ofereceHorario) return vazio`) fechava a conversa toda.
//
// Ou seja: eu tinha escrito uma trava que só acordava no instante de oferecer
// horário. Tudo que vem ANTES do horário -- e é onde a cliente decide -- saía
// sem nenhuma conferência: preço, "com formol", "progressiva primeiro".
//
// Então a ambiguidade passa a ser medida a partir DAS PALAVRAS DELA e do
// catálogo, sem depender de foco nenhum. Se o que ela pediu cabe em mais de um
// serviço, a resposta não pode fechar preço, horário nem atributo: tem que
// perguntar qual. O foco continua servindo para as outras portas, mas não é
// mais o interruptor geral.
//
// "Esse valor é com formol ou sem formol?" é o caso exemplar: ela escreveu as
// DUAS polaridades na mesma frase. Isso não é preferência, é pergunta -- e era
// justo o que `pontuacao` descartava, porque via a polaridade oposta e jogava
// os dois irmãos fora.

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
  /\b(quero|queria|querendo|gostaria|gostava|desejo|pretendo|preciso|vou fazer|posso fazer|pode fazer|marcar|agendar|marca|agenda|fazer)\b/i;

// Perguntar quanto custa é pedir informação sobre um serviço, e é por aí que a
// maioria das conversas começa: "Qual o valor da progressiva?". Não tem verbo
// de intenção nenhum, e mesmo assim é aí que a ambiguidade nasce -- o salão tem
// cinco progressivas. Sem esta linha, a conversa de 16/09 inteira ficava fora
// da conta só porque ela foi educada e perguntou o preço em vez de mandar
// "quero fazer progressiva".
const PERGUNTA_DE_PRECO = /\b(valor|valores|pre[çc]o|pre[çc]os|quanto|custa|sai por|fica quanto)\b/i;

// "com formol ou sem formol?", "3D ou 4D?" -- ela está PERGUNTANDO a diferença,
// não escolhendo. Frase com "ou" dentro de uma pergunta reabre a escolha em vez
// de fechá-la.
const PERGUNTA_COM_OU = /[^.!?\n]*\bou\b[^.!?\n]*\?/i;

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
  // O corte de tamanho era `> 3`, e ele engolia justo o que separa "Progressiva
  // 3D" de "Progressiva 4D": as duas viravam a mesma palavra ['progressiva'] e
  // o catálogo ficava sem como diferenciá-las. Quem tira conectivo é a lista de
  // irrelevantes, que é explícita; tamanho não é critério de sentido.
  return normalizar(nome)
    .split(/[^a-z0-9]+/)
    .filter((p) => p.length > 1 && !IRRELEVANTES.has(p));
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
    // Verbo de pedido, pergunta de preco ou pergunta com "ou" dentro: as tres
    // sao a cliente falando de um servico que ela ainda vai fazer.
    if (INTENCAO.test(texto) || PERGUNTA_DE_PRECO.test(texto) || PERGUNTA_COM_OU.test(texto)) {
      achouVerbo = true;
    }
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
    const temOposta = new RegExp(`\\b${oposta}\\s+${palavra}\\b`).test(texto);
    const temEsta = new RegExp(`\\b${preposicao}\\s+${palavra}\\b`).test(texto);
    // 16/09: "Esse valor e com formol ou sem formol?" tem as DUAS polaridades.
    // Descartar pela oposta jogava fora os dois irmaos exatamente na frase em
    // que ela pergunta a diferenca entre eles. Polaridade so descarta quando ela
    // escolheu um lado: escreveu a oposta e NAO escreveu esta.
    if (temOposta && !temEsta) return null;
  }

  // FRAÇÃO DO NOME, E NÃO CONTAGEM BRUTA.
  //
  // Contagem bruta premiava nome comprido: "Quanto custa o corte?" empatava
  // "Corte" com "Corte junto com alisamento -- cabelo curto (no fim)", porque
  // as duas casavam uma palavra. Cinco opções para uma pergunta que tem uma
  // resposta só, e a trava virava perguntação inútil.
  //
  // Fração resolve: "Corte" fica 1/1, os adicionais ficam 1/3. Já "progressiva"
  // continua empatando as cinco progressivas em 1/2 cada, porque nenhuma delas
  // é coberta inteira -- que é exatamente a ambiguidade de verdade.
  const palavras = palavrasDoServico(nomeDoServico);
  if (palavras.length === 0) return null;
  const casadas = palavras.filter((p) => texto.includes(raiz(p))).length;
  return casadas === 0 ? 0 : casadas / palavras.length;
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

// "Qual delas?", "qual dos dois?" -- a pergunta aponta para a lista que acabou
// de ser dita, sem repetir os nomes.
const PERGUNTA_DE_REFERENCIA =
  /\bqual(?:is)?\s+(?:delas|deles|dessas|desses|das duas|dos dois|voc[êe]\s+(?:quer|prefere|gostaria))\b/i;

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
 * A resposta PERGUNTA qual dos serviços, em vez de escolher um.
 *
 * Existe para não punir a resposta certa. "Qualquer progressiva fica R$ 200 --
 * 3D, 4D, japonesa, com ou sem formol. Qual você quer?" tem dinheiro dentro e
 * mesmo assim é exatamente o que se quer que ele escreva.
 *
 * A pergunta precisa ser sobre o SERVIÇO: "Qual dia você prefere?" também é uma
 * pergunta de escolha e não resolve nada aqui.
 */
export function perguntaQualServico(textos: string[], opcoes: string[]): boolean {
  if (opcoes.length === 0) return false;
  for (const texto of textos) {
    const nomeiaOpcao = opcoes.some((nome) => mencionaServico(texto, nome));
    for (const frase of texto.split(/(?<=[.!?…])\s+|\n+/)) {
      if (!frase.includes('?')) continue;
      if (!PERGUNTA_DE_ESCOLHA.test(frase) && !PERGUNTA_COM_OU.test(frase)) continue;
      // A pergunta nomeia o serviço: "Qual progressiva você quer?".
      if (opcoes.some((nome) => mencionaServico(frase, nome))) return true;
      // Ou ela aponta para a lista que veio na frase anterior: "Temos 3D, 4D,
      // japonesa, com e sem formol. Qual delas você quer?". É assim que se
      // escreve isso em português, e barrar essa forma seria barrar a resposta
      // certa.
      if (PERGUNTA_DE_REFERENCIA.test(frase) && nomeiaOpcao) return true;
    }
  }
  return false;
}

/**
 * A resposta FECHA alguma coisa: diz um valor, oferece um horário, ou afirma um
 * dos serviços como se estivesse combinado.
 *
 * É o gesto que a ambiguidade proíbe. Enquanto ela não disser qual, tudo isso é
 * o agente decidindo no lugar dela.
 */
function fechaAlgumaCoisa(textos: string[], opcoes: string[]): boolean {
  if (textos.some((t) => DINHEIRO.test(t) || HORARIO.test(t))) return true;
  return opcoes.some((nome) => afirmaServico(textos, nome));
}

/**
 * O que falta antes de o agente poder seguir com este serviço.
 *
 * `historico` é a conversa inteira, as duas vozes -- sem a voz dela não dá
 * para saber se ela escolheu. `catalogo` são os nomes dos serviços do salão.
 *
 * `nomeDoServico` é o foco da agenda, e desde 16/09 ele é OPCIONAL de verdade:
 * a conferência de ambiguidade roda com ele null, que é o estado em que a
 * conversa passa a maior parte do tempo. Ver o cabeçalho deste arquivo.
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

  // Afirmar um serviço que ela nunca pediu -- ou que ela já disse que não é --
  // é a frase que fecha a decisão no lugar dela.
  if (nomeDoServico && (escolha === 'NUNCA' || escolha === 'NEGOU') && afirmaServico(textos, nomeDoServico)) {
    return { falta: 'AFIRMOU', opcoes: cabem };
  }

  // IRMÃOS. Ela pediu "uma progressiva" e o salão tem cinco.
  //
  // Esta porta não pergunta mais pelo foco da agenda. O que ela pediu cabe em
  // mais de um serviço; enquanto ela não disser qual, a resposta não fecha
  // preço, horário nem atributo. A única saída é PERGUNTAR qual -- e quem
  // pergunta passa.
  const ambiguo =
    cabem.length > 1 && (!nomeDoServico || cabem.includes(nomeDoServico));
  if (ambiguo && !perguntaQualServico(textos, cabem) && fechaAlgumaCoisa(textos, cabem)) {
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
