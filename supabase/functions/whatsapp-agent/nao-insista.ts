// ERRAR É UM PROBLEMA. CONTINUAR NO ERRO É PIOR.
//
// 16/09, no número de verdade, com todas as travas anteriores já no ar:
//
//   10:07  "Bom dia, Eduarda! A progressiva fica R$ 200,00."
//   10:07  "Ainda estou esperando aquela foto do seu cabelo hoje, pode me mandar?"
//   10:56  cliente: "Esse valor é com formol ou sem formol?"
//   10:58  "Com formol, Eduarda."
//   10:58  "Ainda estou esperando aquela foto do seu cabelo hoje, pode me mandar?"
//
// A segunda frase é a MESMA, caractere por caractere. E a de 10:05 dela ("Qual
// o valor da progressiva?") é igual à de 15:38 do dia anterior -- ela perguntou
// a mesma coisa duas vezes porque a primeira resposta não serviu.
//
// Duas coisas diferentes acontecem aí, e as duas moram neste arquivo:
//
// 1. O AGENTE SE REPETE. Ele reenvia uma frase que já mandou, como se a
//    conversa não tivesse andado. Para a cliente isso lê como robô travado --
//    e, pior, sinaliza que o que ela escreveu no meio não foi lido.
//
// 2. A CLIENTE VOLTOU NO MESMO PONTO. Ela repete a pergunta, ou pergunta "A ou
//    B?" sobre algo que ele já afirmou, ou diz que não é aquilo. Isso é ela
//    dizendo, com todas as letras, que a resposta anterior estava errada ou
//    incompleta.
//
// O caso 1 é invariante e vira trava: o turno volta uma vez. O caso 2 não dá
// para travar -- não existe resposta "proibida" quando a cliente corrige -- mas
// dá para AVISAR: o turno começa com uma linha dizendo que ela voltou, e em
// cima do quê. Sem esse aviso o modelo lê o histórico como uma lista de falas
// simpáticas e não percebe que uma delas é uma reclamação.
//
// Por que não é só prompt: "não se repita" é uma frase que o modelo concorda e
// desobedece. A resposta de 10:58 saiu de um modelo que já tinha, no prompt,
// regra de não repetir pergunta feita.

import type { Fala } from './antes-do-horario.ts';

/** Abaixo disso a frase é curta demais para a repetição significar alguma coisa. */
const CURTA_DEMAIS = 20;

/** Quantas palavras de conteúdo a frase precisa ter para a comparação valer. */
const CONTEUDO_MINIMO = 4;

/** Quanto do conteúdo da frase menor precisa estar na maior para serem a mesma. */
const PARECIDO = 0.8;

const VAZIAS = new Set([
  'para', 'pelo', 'pela', 'esse', 'essa', 'isso', 'aqui', 'ainda', 'tambem',
  'entao', 'porque', 'quando', 'como', 'voce', 'vocie', 'seu', 'sua', 'dele',
  'dela', 'mais', 'menos', 'muito', 'pouco', 'sobre', 'depois', 'antes',
  'estou', 'esta', 'sera', 'pode', 'posso', 'tenho', 'quer', 'aquela', 'aquele',
]);

function normalizar(texto: string): string {
  return texto
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** As frases de um texto, cada uma já normalizada. */
export function frases(texto: string): string[] {
  return texto
    .split(/(?<=[.!?…])\s+|\n+/)
    .map(normalizar)
    .filter((f) => f.length >= CURTA_DEMAIS);
}

function conteudo(frase: string): Set<string> {
  return new Set(frase.split(' ').filter((p) => p.length > 3 && !VAZIAS.has(p)));
}

/**
 * O que a frase AFIRMA de concreto: números e polaridades.
 *
 * "A progressiva COM formol fica R$ 200" e "A progressiva SEM formol fica
 * R$ 200" compartilham quase todo o conteúdo e são mensagens opostas. Enquanto
 * isto diferir, as duas frases não são a mesma frase, por mais parecidas que
 * pareçam.
 */
function marcasConcretas(frase: string): string {
  const numeros = frase.match(/\d+/g) ?? [];
  const polaridades = [...frase.matchAll(/\b(com|sem)\s+([a-z0-9]+)/g)].map((m) => m[0]);
  return [...numeros, ...polaridades].sort().join('|');
}

/** As duas frases dizem a mesma coisa. */
export function mesmaFrase(a: string, b: string): boolean {
  if (a === b) return true;
  if (marcasConcretas(a) !== marcasConcretas(b)) return false;

  const ca = conteudo(a);
  const cb = conteudo(b);
  const menor = Math.min(ca.size, cb.size);
  if (menor < CONTEUDO_MINIMO) return false;

  let juntos = 0;
  for (const palavra of ca) if (cb.has(palavra)) juntos++;
  return juntos / menor >= PARECIDO;
}

/**
 * As frases da resposta que o agente JÁ MANDOU nesta conversa.
 *
 * Lista vazia quer dizer que a resposta traz alguma coisa nova. Qualquer item é
 * uma frase reenviada -- o trecho devolvido é o texto original, não o
 * normalizado, para caber no recado e no log.
 */
export function frasesRepetidas(textos: string[], jaDitoPeloAgente: string[]): string[] {
  const antigas = jaDitoPeloAgente.flatMap(frases);
  if (antigas.length === 0) return [];

  const repetidas: string[] = [];
  for (const texto of textos) {
    for (const bruta of texto.split(/(?<=[.!?…])\s+|\n+/)) {
      const nova = normalizar(bruta);
      if (nova.length < CURTA_DEMAIS) continue;
      if (antigas.some((velha) => mesmaFrase(nova, velha))) repetidas.push(bruta.trim());
    }
  }
  return repetidas;
}

// ---------------------------------------------------------------------------
// A CLIENTE VOLTOU NO MESMO PONTO
// ---------------------------------------------------------------------------

/** Por que a última leva dela é uma correção do que o agente disse. */
export type Volta =
  | { tipo: 'REPETIU_PERGUNTA'; trecho: string; antes: string }
  | { tipo: 'PEDIU_ENTRE_DOIS'; trecho: string }
  | { tipo: 'DISSE_QUE_NAO'; trecho: string };

const NEGACAO =
  /(^|\W)n[ãa]o\s+([ée]|eh|quero|queria|vai ser|era|vou|pode|seria)(?![\p{L}\p{N}])|nada disso|de jeito nenhum|(^|\W)n[ãa]o[\s\p{P}]*$/iu;

/** Pergunta com "ou" dentro: "com formol ou sem formol?". */
const ENTRE_DOIS = /[^.!?\n]*\bou\b[^.!?\n]*\?/i;

/**
 * A última leva da cliente, ou seja, tudo que ela escreveu depois da última
 * fala do agente. É sobre ISSO que o turno tem que responder.
 */
function ultimaLeva(historico: Fala[]): string[] {
  const leva: string[] = [];
  for (let i = historico.length - 1; i >= 0; i--) {
    const fala = historico[i];
    if (!fala) continue;
    if (fala.direction === 'OUTBOUND') break;
    const texto = String(fala.text ?? '').trim();
    if (texto.length > 0) leva.unshift(texto);
  }
  return leva;
}

/**
 * A cliente está voltando num ponto que o agente já tratou -- e voltar é ela
 * dizendo que a resposta anterior não serviu.
 *
 * Devolve lista vazia quando a conversa está andando para frente.
 */
export function voltasDaCliente(historico: Fala[]): Volta[] {
  const leva = ultimaLeva(historico);
  if (leva.length === 0) return [];

  const anteriores = historico
    .filter((f) => f.direction === 'INBOUND')
    .map((f) => String(f.text ?? ''))
    .slice(0, -leva.length);

  const voltas: Volta[] = [];
  for (const texto of leva) {
    if (NEGACAO.test(texto)) {
      voltas.push({ tipo: 'DISSE_QUE_NAO', trecho: texto });
      continue;
    }
    if (ENTRE_DOIS.test(texto)) {
      voltas.push({ tipo: 'PEDIU_ENTRE_DOIS', trecho: texto });
      continue;
    }
    if (!texto.includes('?')) continue;

    const nova = normalizar(texto);
    if (nova.length < CURTA_DEMAIS) continue;
    const igual = anteriores.find((velha) =>
      frases(velha).some((f) => mesmaFrase(nova, f))
    );
    if (igual) voltas.push({ tipo: 'REPETIU_PERGUNTA', trecho: texto, antes: igual });
  }
  return voltas;
}

/**
 * A linha que entra no prompt quando ela voltou. Vazia quando não voltou.
 *
 * Isto não proíbe nada -- diz ao modelo o que ele não enxerga sozinho: que a
 * mensagem que ele vai responder é uma correção, e não mais uma pergunta.
 */
export function avisoDeVolta(voltas: Volta[]): string {
  if (voltas.length === 0) return '';

  const linhas = voltas.map((v) => {
    if (v.tipo === 'REPETIU_PERGUNTA') {
      return (
        '- Ela PERGUNTOU DE NOVO: "' +
        v.trecho +
        '". Ela já tinha perguntado isso ("' +
        v.antes +
        '") e você já respondeu. Se ela voltou, a sua resposta não serviu: ' +
        'ou não respondeu o que ela perguntou, ou respondeu pela metade. ' +
        'Não repita o que você já disse -- descubra o que faltou.'
      );
    }
    if (v.tipo === 'PEDIU_ENTRE_DOIS') {
      return (
        '- Ela perguntou ENTRE DUAS COISAS: "' +
        v.trecho +
        '". Isso quer dizer que o que você disse antes não distinguia as duas, ' +
        'e que ela ainda NÃO escolheu. Responder escolhendo uma delas por ela é ' +
        'o erro. Explique a diferença e devolva a escolha para ela.'
      );
    }
    return (
      '- Ela disse que NÃO: "' +
      v.trecho +
      '". Alguma coisa que você deu como certa está errada. Abandone essa ' +
      'suposição agora, diga em voz alta que você entendeu errado, e pergunte.'
    );
  });

  return (
    'ATENÇÃO -- A CLIENTE VOLTOU NUM PONTO QUE VOCÊ JÁ TINHA TRATADO:\n' +
    linhas.join('\n') +
    '\nA primeira frase da sua resposta trata disso. Reconhecer que você errou ' +
    'custa uma linha; insistir no erro custa a cliente.'
  );
}
