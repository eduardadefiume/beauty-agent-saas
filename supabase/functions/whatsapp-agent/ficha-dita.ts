// O QUE ELA JÁ CONTOU DO CABELO.
//
// 01/10, DEV: a Marina escreveu "já fiz luzes aí ano passado" e ouviu, em
// sequência, "você já fez alguma química?", "faz quanto tempo?" e "essa
// química tinha formol?" -- três perguntas que ela já tinha respondido ou que
// não cabiam (formol é de alisamento, não de luzes). O modelo não anotou;
// o código lê o óbvio e anota antes dele, como já faz com o nome.
//
// Só o que ela disse com todas as letras. Na dúvida, não anota: a pergunta
// continua na ficha e o modelo pergunta.

export type FatosDaFicha = {
  temQuimica?: boolean;
  quimicaQual?: string;
  quimicaHaQuantoTempo?: string;
  temColoracao?: boolean;
};

const sem = (t: string) => ` ${t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')} `;

// Química do fio, com o nome que vai para a ficha.
const QUIMICAS: Array<[RegExp, string]> = [
  [/\bluzes\b/, 'luzes'],
  [/\bmechas?\b/, 'mechas'],
  [/\bmorena iluminada\b/, 'morena iluminada'],
  [/\bbalaiagem|balayage\b/, 'balaiagem'],
  [/\bdescolor/, 'descoloração'],
  [/\bplatinad/, 'platinado'],
  [/\bprogressiva\b/, 'progressiva'],
  [/\balisament|\balisei\b/, 'alisamento'],
  [/\bselante\b/, 'selante'],
  [/\bbotox\b/, 'botox'],
  [/\brelaxamento\b/, 'relaxamento'],
  [/\b(escova )?definitiva\b/, 'definitiva'],
  [/\bqueratin|keratin/, 'queratina'],
];

const NEGA_QUIMICA =
  /\b(nunca fiz|nao fiz|nao tenho|nao tem|sem) (nenhuma )?quimica\b|\bcabelo (e |eh )?virgem\b|\bnunca fiz nada\b/;
const AFIRMA_QUIMICA_GENERICA = /\b(fiz|tenho|tem|faco|fazia) (uma |alguma )?quimica\b/;

const NEGA_COR =
  /\b(nao|nunca) (tenho|tem|uso|pinto|pintei|fiz) (coloracao|tintura|tinta)\b|\bnunca pintei\b|\bnao pinto\b|\bsem (coloracao|tintura)\b|\bnao tenho (coloracao|tintura)\b|\bnem (coloracao|tintura)\b/;
const AFIRMA_COR = /\b(pinto|tinjo|pintei|tingi)\b|\b(tenho|fiz|faco) (coloracao|tintura)\b/;

// Quando: o texto vai cru para o banco, que sabe converter (app.periodo_para_data).
const QUANDO =
  /\b(ano passado|mes passado|semana passada|ontem|anteontem|(esse|este) ano|faz [^.,!?;]{1,30}|ha [^.,!?;]{1,25}|(uns |umas )?(\d+|um|uma|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|quinze|vinte|meio)( e meio)? (anos?|meses|mes|semanas?|dias?)( e meio)?|em (janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)[^.,!?;]{0,20})(?=[\s.,!?;]|$)/;

// 01/10, ao vivo: "quero fazer progressiva, nunca fiz química" virou
// "tem progressiva". O nome da química sozinho não diz nada: "quero luzes" é o
// que ela QUER, "fiz luzes" é o que ela TEM. Cada trecho da frase é lido à
// parte e só conta como histórico com verbo de passado/posse ("fiz", "tenho")
// ou com tempo junto ("as luzes do ano passado").
const VERBO_DE_HISTORICO =
  /\b(fiz|fez|fazia|faco|tenho|tinha|passei|usei|uso|coloquei|apliquei|retoquei)\b/;
// "Fazer de novo", "retocar": quer de novo o que já tem.
const RENOVA = /\b(de novo|outra vez|retocar|retoque|refazer|manutencao)\b/;
// Tempo junto do pedido é data futura ("mechas em dezembro"), não histórico.
const DESEJO = /\b(quero|queria|gostaria|pretendo|marcar|agendar|quanto|valor|preco)\b/;
// Corta a frase em trechos. " e " só corta antes de outro verbo, para não
// partir "um ano e meio".
const CORTE_DE_TRECHO =
  /[.,;!?\n]|\s(?:e|mas|so que|porem)\s(?=(?:eu\s)?(?:quero|queria|gostaria|pinto|tinjo|tenho|fiz|nao|nunca|ja|uso|faco|tambem|agora|pretendo)\b)/;

export function fichaDita(falasDela: string[], perguntaAnterior = ''): FatosDaFicha {
  const fatos: FatosDaFicha = {};
  const anterior = sem(perguntaAnterior);
  const respondeTempo =
    /quanto tempo|quando foi|faz quanto/.test(anterior) && /quimica/.test(anterior);
  const historico: string[] = [];
  let negou = false;
  let afirmouGenerico = false;

  for (const fala of falasDela) {
    const inteira = sem(String(fala ?? ''));
    if (inteira.trim() === '') continue;
    let anteriorNaFala: string[] = [];
    let anteriorEraHistorico = false;
    for (const pedaco of inteira.split(CORTE_DE_TRECHO)) {
      const t = ` ${pedaco ?? ''} `;
      if (t.trim() === '') continue;
      const quais = QUIMICAS.filter(([re]) => re.test(t)).map(([, nome]) => nome);
      // "não tenho coloração NEM progressiva": negada, não conta.
      const naoNegadas = quais.filter(
        (nome) =>
          !new RegExp(
            `\\b(nem|sem|nunca fiz|nao fiz|nao tenho|nunca) (a |as |o )?${sem(nome).trim()}`
          ).test(t)
      );
      const quando = t.match(QUANDO);
      const eHistorico =
        naoNegadas.length > 0 &&
        (VERBO_DE_HISTORICO.test(t) || RENOVA.test(t) || (!!quando && !DESEJO.test(t)));
      // "quero progressiva de novo, fiz uma faz 4 meses" / "retocar minhas
      // mechas, fiz em junho" (01/10, ao vivo): o trecho fala da de antes.
      const retomaAnterior =
        naoNegadas.length === 0 &&
        quais.length === 0 &&
        anteriorNaFala.length > 0 &&
        VERBO_DE_HISTORICO.test(t) &&
        (/\b(uma|um|ela|essa|esse|isso)\b/.test(t) || (!!quando && anteriorEraHistorico));
      if (naoNegadas.length > 0) {
        anteriorNaFala = naoNegadas;
        anteriorEraHistorico = eHistorico;
      }
      if (eHistorico || retomaAnterior) {
        historico.push(...(eHistorico ? naoNegadas : anteriorNaFala));
        if (quando) fatos.quimicaHaQuantoTempo = limparTempo(quando[0]);
      } else if (respondeTempo && quando && quais.length === 0) {
        fatos.quimicaHaQuantoTempo = limparTempo(quando[0]);
      }
      if (NEGA_QUIMICA.test(t)) negou = true;
      else if (AFIRMA_QUIMICA_GENERICA.test(t)) afirmouGenerico = true;

      if (NEGA_COR.test(t)) fatos.temColoracao = false;
      else if (AFIRMA_COR.test(t)) fatos.temColoracao = true;
    }
  }

  if (historico.length > 0) {
    fatos.temQuimica = true;
    fatos.quimicaQual = [...new Set(historico)].join(', ');
  } else if (negou) {
    fatos.temQuimica = false;
    delete fatos.quimicaHaQuantoTempo;
  } else if (afirmouGenerico) {
    fatos.temQuimica = true;
  } else if (!respondeTempo) {
    delete fatos.quimicaHaQuantoTempo;
  }
  return fatos;
}

// "faz 6 meses e quero marcar dia 5": o tempo acaba onde começa o pedido.
function limparTempo(t: string): string {
  return t
    .replace(/\s(mas|quero|queria|pra|para|porque|so que|e quero|e queria|e agora|e ai)\s.*$/, '')
    .trim();
}

// Formol é pergunta de alisamento. Luzes, mechas e descoloração não levam.
export function quimicaPodeTerFormol(qual: string | null | undefined): boolean {
  if (!qual || !qual.trim()) return true;
  const t = sem(qual);
  if (
    /\b(progressiva|alisament|selante|botox|relaxamento|definitiva|queratin|keratin|formol|realinhamento|plastica|blindagem|escova (inteligente|marroquina|japonesa))/.test(
      t
    )
  )
    return true;
  return !/\b(luzes|mechas?|descolor|platinad|iluminad|balaiagem|balayage|reflexo|ombre|tintura|coloracao|loir)/.test(
    t
  );
}

// "Já te mando uma foto" -- a atendente nunca manda foto para a cliente
// avaliar: quem manda é ela. Inverte para o pedido certo.
export function quemMandaAFoto(texto: string): string {
  return texto.replace(
    /(^|[.!?]\s+)(j[áa]\s+)?(eu\s+)?(te\s+mando|vou\s+te\s+mandar|posso\s+te\s+mandar|te\s+envio|vou\s+te\s+enviar)\s+(uma|a|as|umas)\s+(fotos?)/gi,
    (_m, inicio: string, _ja, _eu, _verbo, artigo: string, foto: string) =>
      `${inicio}Me manda ${artigo.toLowerCase()} ${foto.toLowerCase()}`
  );
}

// A FOTO DO TOM QUE ELA QUER.
//
// 01/10, ao vivo: a Luana mandou a foto com "quero esse loiro mel" logo depois
// de "me manda uma foto do tom que você quer alcançar?". O modelo respondeu
// "amei a referência" e não anotou; a ficha ficou dizendo que faltava o tom,
// o horário travou e, quando ela aceitou o horário, ouviu "me confirma, aquela
// foto é o tom que você quer?". Foto que responde o pedido do tom, ou foto com
// legenda de desejo, É o tom. Foto do cabelo dela ("meu cabelo hoje") não é.
type FalaComMidia = { direction?: unknown; text?: unknown; mediaKind?: unknown };

const PEDIU_O_TOM =
  /tom que (voc[eê] )?(quer|deseja)|cor que (voc[eê] )?(quer|deseja)|refer[eê]ncia|quer alcan[cç]ar|foto do (tom|resultado)/i;
const LEGENDA_DE_DESEJO =
  /\b(quero|queria|gostaria|sonho|amo|amei)\b.*\b(esse|essa|assim|isso|igual|desse|dessa|deste|desta)\b|\b(esse|essa|este|esta) (tom|cor|loiro|ruivo|castanho|mel|morena|luzes|mechas|resultado)\b|refer[eê]ncia|inspira[cç]/i;
const E_O_CABELO_DELA = /\b(meu cabelo|como (ele )?est[aá]|hoje|atual|agora)\b/i;

export function tomDaFoto(historico: FalaComMidia[]): string | null {
  let ultimaDoAgente = '';
  let tom: string | null = null;
  for (const f of historico) {
    const texto = String(f?.text ?? '').trim();
    if (f?.direction !== 'INBOUND') {
      if (texto) ultimaDoAgente = texto;
      continue;
    }
    const foto = /IMAGE/i.test(String(f?.mediaKind ?? ''));
    if (!foto) continue;
    if (E_O_CABELO_DELA.test(texto) && !LEGENDA_DE_DESEJO.test(texto)) continue;
    if (LEGENDA_DE_DESEJO.test(texto) || PEDIU_O_TOM.test(ultimaDoAgente)) {
      tom = texto ? `foto de referência: "${texto}"` : 'foto de referência';
    }
  }
  return tom;
}
