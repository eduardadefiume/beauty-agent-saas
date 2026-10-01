// ELA DISSE O NOME DO SERVIÇO, E NÃO ERA ESTE.
//
// 01/10, DEV: a atendente ofereceu "dia 3/12 às 9h" falando do teste de mecha
// e das luzes na mesma frase. A Luana respondeu "pode sim, as luzes dia 3 às
// 9h" -- e foi marcado TESTE DE MECHA às 9h, sem sinal, com "se aprovar, as
// luzes na sequência". Ela nomeou o serviço com todas as letras.
//
// Regra mecânica: se a última fala dela nomeia um serviço do catálogo e o
// serviço que vai ser marcado não aparece nessa fala, não marca.

const sem = (t: string) =>
  ` ${t
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()} `;

/** Os serviços do catálogo que ela nomeou, do mais longo para o mais curto. */
function nomeados(fala: string, catalogo: string[]): string[] {
  let t = sem(fala);
  const achados: string[] = [];
  for (const nome of [...catalogo].sort((a, b) => b.length - a.length)) {
    const n = sem(nome);
    if (n.trim().length < 3) continue;
    if (t.includes(n)) {
      achados.push(nome);
      t = t.replace(n, ' ');
    }
  }
  return achados;
}

/**
 * O serviço que ela pediu, quando é OUTRO que não o que vai ser marcado.
 * null quando ela não nomeou serviço nenhum, ou nomeou o que vai ser marcado.
 */
export function pediuOutroServico(
  levaDela: string[],
  servicoQueVaiMarcar: string | null | undefined,
  catalogo: string[]
): string | null {
  if (!servicoQueVaiMarcar) return null;
  const fala = levaDela.join(' ');
  const ditos = nomeados(fala, catalogo);
  if (ditos.length === 0) return null;
  if (ditos.some((d) => sem(d) === sem(servicoQueVaiMarcar))) return null;
  return ditos[0];
}
