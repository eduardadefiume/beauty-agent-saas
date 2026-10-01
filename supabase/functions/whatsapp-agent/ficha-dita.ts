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

export function fichaDita(falasDela: string[], perguntaAnterior = ''): FatosDaFicha {
  const fatos: FatosDaFicha = {};
  const anterior = sem(perguntaAnterior);
  for (const fala of falasDela) {
    const t = sem(String(fala ?? ''));
    if (t.trim() === '') continue;

    const quais = QUIMICAS.filter(([re]) => re.test(t)).map(([, nome]) => nome);
    // "não tenho coloração NEM progressiva" nega a progressiva que aparece no texto.
    const quaisAfirmadas = quais.filter(
      (nome) => !new RegExp(`\\b(nem|sem|nunca fiz|nao fiz|nao tenho) ${sem(nome).trim()}`).test(t)
    );

    if (NEGA_QUIMICA.test(t) && quaisAfirmadas.length === 0) {
      fatos.temQuimica = false;
    } else if (quaisAfirmadas.length > 0) {
      fatos.temQuimica = true;
      fatos.quimicaQual = [
        ...new Set([...(fatos.quimicaQual?.split(', ') ?? []), ...quaisAfirmadas]),
      ]
        .filter(Boolean)
        .join(', ');
    } else if (AFIRMA_QUIMICA_GENERICA.test(t)) {
      fatos.temQuimica = true;
    }

    // O tempo só vale se a frase fala da química, ou se a pergunta anterior era o tempo dela.
    const falaDeQuimica = quaisAfirmadas.length > 0 || /\bquimica\b/.test(t);
    const respondeTempo =
      /quanto tempo|quando foi|faz quanto/.test(anterior) && /quimica/.test(anterior);
    if (falaDeQuimica || respondeTempo) {
      const m = t.match(QUANDO);
      // "faz 6 meses e quero marcar dia 5": o tempo acaba onde começa o pedido.
      if (m)
        fatos.quimicaHaQuantoTempo = m[0]
          .replace(/\s(mas|quero|queria|pra|para|porque|so que|e quero|e queria|e agora|e ai)\s.*$/, '')
          .trim();
    }

    if (NEGA_COR.test(t)) fatos.temColoracao = false;
    else if (AFIRMA_COR.test(t)) fatos.temColoracao = true;
  }
  return fatos;
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
