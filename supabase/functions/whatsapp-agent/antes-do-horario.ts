// NAO SE OFERECE HORARIO DE UM PROCEDIMENTO QUE A CLIENTE NAO ESCOLHEU.
//
// 14/09, a noite. Uma cliente nova escreveu "gostaria de marcar um
// procedimento". O agente perguntou o nome, pediu foto do cabelo, perguntou de
// quimica, de progressiva, de formol -- oito mensagens de interrogatorio -- e
// terminou com "Tenho amanha, terca, as 13h, pode ser?".
//
// Horario de QUE? No banco: ele consultou a agenda de "Mechas morena
// iluminada". A cliente nunca disse isso. Ela e ruiva, pinta todo mes, e tinha
// acabado de contar que fez progressiva com formol ha um mes -- exatamente o
// caso em que as regras de quimica do salao mandam NAO clarear.
//
// E em nenhum momento ele disse o que era, nem quanto custava.
//
// A raiz e a mesma de dois defeitos anteriores: a conversa e guiada pela lista
// de pendencias da FICHA, e o que nao esta na lista nunca e perguntado. Faltou
// o nome, faltou o visagismo, e agora falta a pergunta que vem antes de todas:
// o que voce quer fazer?
//
// Esta trava e a metade mecanica do conserto. Ela nao adivinha se a cliente
// escolheu -- ela verifica uma coisa simples e verdadeira sempre: se voce esta
// oferecendo horario, a cliente precisa ter ouvido de voce QUAL procedimento e
// POR QUANTO. Se nem o nome do servico apareceu na conversa, ela esta sendo
// convidada a marcar uma coisa que ela nao sabe o que e.

/** Um horario concreto na mensagem: "13h", "14:30", "quinta 18/09". */
const HORARIO = /\b\d{1,2}\s*h(\s*\d{2})?\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}\/\d{1,2}\b/i;

/** Qualquer valor em dinheiro. */
const DINHEIRO = /R\$\s*[\d.,]+|\b[\d.,]+\s*(reais|real)\b/i;

const IRRELEVANTES = new Set([
  'de', 'da', 'do', 'com', 'sem', 'para', 'por', 'e', 'a', 'o', 'as', 'os',
  'no', 'na', 'em', 'um', 'uma', 'teste', 'dia', 'mesmo', 'semana',
]);

function normalizar(texto: string): string {
  return texto
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase();
}

/**
 * As palavras que identificam um servico. "Mechas morena iluminada" vira
 * ['mechas','morena','iluminada']; o que e conectivo ou generico sai fora,
 * senao "teste" casaria com qualquer frase sobre teste de mecha.
 */
export function palavrasDoServico(nome: string): string[] {
  return normalizar(nome)
    .split(/[^a-z0-9]+/)
    .filter((p) => p.length > 3 && !IRRELEVANTES.has(p));
}

/** A conversa ja nomeou este servico em alguma fala do agente. */
export function servicoFoiDito(textos: string[], nomeDoServico: string): boolean {
  const palavras = palavrasDoServico(nomeDoServico);
  if (palavras.length === 0) return true;
  const tudo = normalizar(textos.join(' '));
  return palavras.some((p) => tudo.includes(p));
}

/** Alguma fala do agente ja disse um valor. */
export function precoFoiDito(textos: string[]): boolean {
  return textos.some((t) => DINHEIRO.test(t));
}

/** A resposta oferece um horario concreto. */
export function ofereceHorario(textos: string[]): boolean {
  return textos.some((t) => HORARIO.test(t));
}

/**
 * true quando o agente esta oferecendo horario sem a cliente ter ouvido qual
 * procedimento e/ou quanto custa.
 *
 * `ditoAntes` sao as falas do agente na conversa inteira, nao so deste turno:
 * se ele ja explicou o procedimento e o valor tres mensagens atras, nao ha por
 * que repetir.
 */
export function horarioSemProcedimentoOuPreco(
  textos: string[],
  ditoAntes: string[],
  nomeDoServico: string | null
): { falta: 'PROCEDIMENTO' | 'PRECO' | null } {
  if (!ofereceHorario(textos)) return { falta: null };

  const tudo = [...ditoAntes, ...textos];
  if (!nomeDoServico || !servicoFoiDito(tudo, nomeDoServico)) {
    return { falta: 'PROCEDIMENTO' };
  }
  if (!precoFoiDito(tudo)) return { falta: 'PRECO' };
  return { falta: null };
}

/** O que o agente ja falou nesta conversa, na ordem. */
export function falasDoAgente(volatil: unknown): string[] {
  const historico = (volatil as { history?: unknown } | null)?.history;
  if (!Array.isArray(historico)) return [];
  return historico
    .filter((f) => (f as { direction?: unknown })?.direction === 'OUTBOUND')
    .map((f) => (f as { text?: unknown }).text)
    .filter((t): t is string => typeof t === 'string' && t.trim().length > 0);
}
