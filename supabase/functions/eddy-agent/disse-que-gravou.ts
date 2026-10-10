// "JÁ AJUSTEI" SEM TER GRAVADO NADA.
//
// A trava do turno (index.ts) segura a resposta que diz que gravou quando
// nenhuma ferramenta que grava foi chamada. Ela reconhece a frase por uma
// lista de verbos -- e a lista só tinha anotar, gravar, registrar, cadastrar,
// salvar, guardar, atualizar, arquivar e corrigir.
//
// 10/10, PRODUÇÃO, William: "Beleza, corte também entra no sinal de R$ 50
// então. Já ajustei." Nada foi gravado, e "ajustei" não estava na lista.
// Entram os outros jeitos de dizer que fez: ajustei, coloquei, incluí,
// acrescentei, adicionei, mudei, troquei, tirei, removi, defini, configurei,
// ativei/ativado, liguei/ligado, desliguei, marquei, botei, lancei, deixei
// (registrado/anotado/...), "tá feito", "pronto, ...". Só passado/particípio:
// "posso ajustar?", "quer que eu ative?", "vou anotar" são perguntas e
// promessas, não afirmações.

// A lista antiga fica como era (inclusive "ou" e particípio). Os verbos novos
// só na 1ª pessoa ("ajustei") ou com "já" ("já está ajustado"): "horário
// marcado", "a cliente mudou", "o preço inclui" são frases normais do Eddy.
const FEZ = new RegExp(
  '\\b(' +
    [
      '(anot|grav|registr|cadastr|salv|guard|atualiz|arquiv)(ei|ado|ada|ados|adas|ou|amos)',
      'corrig(i|ido|ida|idos|idas|imos)',
      '(ajust|configur|adicion|acrescent|lanc|troqu|mud|alter|ativ|desativ|ligu|desligu|tir|coloqu|bot|apagu|marqu)(ei|amos)',
      '(defin|remov|exclu)i',
      'ja inclui',
      '(ja|tudo) (esta |ta |ficou |foi |fica )?(ajustad|configurad|incluid|ativad|ligad|definid|alterad|mudad|removid|tirad|adicionad|feit)[oa]s?',
      '(esta|ta) feito',
    ].join('|') +
    ')(?![a-z])',
  'i'
);

const sem = (t: string) =>
  String(t ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '');

// "Incluí" só se separa de "o valor inclui" pelo acento, que o `sem` tira.
const COM_ACENTO = /(?<!\p{L})(inclu|exclu)í(?!\p{L})/iu;

export function disseQueGravou(textos: unknown[]): boolean {
  return (textos ?? []).some((m) => {
    const t = String(m ?? '');
    return COM_ACENTO.test(t) || FEZ.test(sem(t));
  });
}
