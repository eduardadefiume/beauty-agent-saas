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
    const n = sem(nome).trim();
    if (n.length < 3) continue;
    // "teste de mechas" e "teste de mecha", "as mecha" e "mechas": cada
    // palavra vale no singular e no plural.
    const padrao = new RegExp(
      ' ' +
        n
          .split(' ')
          .map((w) => w.replace(/s$/, '') + 's?')
          .join(' ') +
        ' '
    );
    if (padrao.test(t)) {
      achados.push(nome);
      t = t.replace(padrao, ' ');
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
  return ditos[0] ?? null;
}

// ELA NÃO PEDIU PARA DESMARCAR ISSO.
//
// 01/10, DEV: a Marina desmarcou as luzes; no turno seguinte perguntou do
// sinal, e a atendente "já cancelei também o teste de mecha de quarta". Ela
// nunca falou do teste. Pode até fazer sentido, mas quem decide é ela.
// Desmarca só o que ela citou -- pelo serviço ou pela data -- nas falas dela.

/** true quando as falas dela citam este agendamento (serviço ou dia DD/MM). */
export function eleaCitouOAgendamento(
  falasDela: string[],
  servico: string,
  quandoDDMM: string
): boolean {
  // sem() troca a barra por espaço: "07/10" chega aqui como "07 10".
  const t = sem(falasDela.join(' '));
  if (nomeados(falasDela.join(' '), [servico]).length > 0) return true;
  const m = quandoDDMM.match(/^(\d{2})\/(\d{2})/);
  if (!m) return false;
  const dia = String(Number(m[1]));
  const mes = String(Number(m[2]));
  return new RegExp(`\\b0?${dia}\\s+0?${mes}\\b|\\bdia\\s+0?${dia}\\b`).test(t);
}

// O TESTE DE MECHA SOZINHO, SÓ SE ELA PEDIU.
//
// Regra da Duda (01/10): no padrão global o teste é feito no começo do
// procedimento, no mesmo dia, dentro do tempo dele. O que se marca é o
// PROCEDIMENTO. O teste sozinho só quando ela quer só o teste. Cada salão
// escolhe o seu modo (app.teste_mecha_config):
//   MESMO_DIA  -> teste sozinho só se ela pediu só o teste
//   ANTES      -> o teste à parte é o normal: não trava
//   SEM_TESTE  -> o salão não faz teste: nunca marca teste
export type ModoDoTeste = 'MESMO_DIA' | 'ANTES' | 'SEM_TESTE';

const E_TESTE = /\btest(e|inho)s?\b.*\bme(ch|x)as?\b|\btest(e|inho)\b/;
const SO_O_TESTE =
  /\b(so|somente|apenas|soh)\b[^.!?]{0,20}\btest(e|inho)|\btest(e|inho)\b[^.!?]{0,30}\b(primeiro|antes|por enquanto|sozinho|depois (eu )?(decido|vejo|marco))\b/;
const NEGA_SO_O_TESTE = /\bnao\b[^.!?]{0,15}\b(so|somente|apenas)\b[^.!?]{0,10}\btest/;

/** true quando marcar o teste sozinho vai contra a regra do salão. */
export function testeSemPedir(
  falasDela: string[],
  servicoQueVaiMarcar: string | null | undefined,
  modo: ModoDoTeste,
  procedimentos: string[]
): boolean {
  if (!servicoQueVaiMarcar || !E_TESTE.test(sem(servicoQueVaiMarcar))) return false;
  if (modo === 'SEM_TESTE') return true;
  if (modo === 'ANTES') return false;
  const t = sem(falasDela.join(' . '));
  if (NEGA_SO_O_TESTE.test(t)) return true;
  if (SO_O_TESTE.test(t)) return false;
  // Citou um procedimento: o que se marca é ele (o teste vai junto).
  // "teste de mechas" não é o serviço "Mechas": tira a expressão do teste antes.
  const semOTeste = ` ${t.replace(/\btest(e|inho)s?( de| da| das| do)? me(ch|x)as?\b/g, ' ')} `;
  const citouProcedimento = procedimentos.some(
    (p) => !E_TESTE.test(sem(p)) && semOTeste.includes(sem(p))
  );
  if (citouProcedimento) return true;
  // Falou de teste sem procedimento nenhum ("marca o teste de mecha"): é o teste.
  return !E_TESTE.test(t);
}
