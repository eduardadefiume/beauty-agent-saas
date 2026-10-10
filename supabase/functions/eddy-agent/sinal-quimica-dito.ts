// O VALOR DO SINAL DA QUÍMICA, COMO O DONO DISSE.
//
// 02/10, DEV, William-robô configurando do zero: "sinal sim mas só pra
// química" e, à pergunta do valor, "50 reais. os outros não". O salão ainda
// não tinha serviço cadastrado, não havia onde gravar, e o Eddy disse "o valor
// de R$ 50 pra química eu guardei aqui". Não guardou.
//
// Agora existe o valor para toda a química (sinal_config.valor_quimica_centavos)
// e o código lê o óbvio e grava antes do modelo, como na devolução. Só lê
// quando a química está na frase dele ou na pergunta que ele respondeu, e
// nenhum procedimento foi nomeado junto do valor. Na dúvida, null: fica com o
// modelo.

const sem = (t: string) =>
  ` ${String(t ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/(\d)\.(\d{3})(?!\d)/g, '$1$2')
    .replace(/\s+/g, ' ')} `;

const POR_EXTENSO: Record<string, number> = {
  dez: 10,
  vinte: 20,
  trinta: 30,
  quarenta: 40,
  cinquenta: 50,
  sessenta: 60,
  setenta: 70,
  oitenta: 80,
  noventa: 90,
  cem: 100,
  'cento e cinquenta': 150,
  duzentos: 200,
};

// Número que não é dinheiro: 24h, 48 horas, 2 dias, 50%, 3x.
const NUMERO =
  /(?:r\$\s*)?(?<![\d,])(\d{1,4}(?:,\d{1,2})?)(?![\d,])(?!\s*(?:%|por ?cento|h\b|hs\b|hrs?\b|horas?\b|dias?\b|semanas?\b|min|mes\b|meses\b|x\b|vezes))/;
const EXTENSO = new RegExp(
  `\\b(${Object.keys(POR_EXTENSO)
    .sort((a, b) => b.length - a.length)
    .join('|')})\\b(?=\\s*(reais|real|conto|pila|r\\$|pra|para|na|nas|em|no|nos|de))`
);

const PROCEDIMENTO =
  /\b(luzes|mechas?|morena iluminada|balaiagem|balayage|ombre|descolor\w*|platinad\w*|coloracao|tintura|tonaliza\w*|progressiva|alisamento|selante|botox|relaxamento|definitiva|queratina|corte|escova|hidratacao|unha|manicure|gloss)\b/;
const NEGA = /\bnao (cobr|quero|vou|tem)|\bsem sinal\b|\bnenhum\b/;
const QUIMICA = /\bquimicas?\b/;

function valorDoTrecho(t: string): number | null {
  const emNumero = t.match(NUMERO)?.[1];
  if (emNumero) {
    const n = Number(emNumero.replace(',', '.'));
    return n > 0 ? n : null;
  }
  const emExtenso = t.match(EXTENSO)?.[1];
  return emExtenso ? (POR_EXTENSO[emExtenso] ?? null) : null;
}

export function valorDaQuimicaDito(fala: string, ultimaDoEddy = ''): number | null {
  const t = sem(fala);
  if (t.trim() === '') return null;
  const trechos = t.split(/[;!?\n]|[.,](?!\d)|(?<!cento)\s(?:e|mas)\s/).map((x) => ` ${x.trim()} `);

  const falaDaQuimica = QUIMICA.test(t);
  if (falaDaQuimica) {
    // 1. O valor está no mesmo trecho que "química".
    for (const tr of trechos) {
      if (!QUIMICA.test(tr) || NEGA.test(tr)) continue;
      const v = valorDoTrecho(tr);
      if (v != null) return v;
    }
    // 2. "sinal só pra química, 50 reais": o valor veio no trecho do lado,
    //    sem procedimento nomeado e sem negação.
    if (trechos.some((tr) => QUIMICA.test(tr) && NEGA.test(tr))) return null;
    for (const tr of trechos) {
      if (QUIMICA.test(tr) || PROCEDIMENTO.test(tr) || NEGA.test(tr)) continue;
      const v = valorDoTrecho(tr);
      if (v != null) return v;
    }
    return null;
  }

  // 3. Respondeu à pergunta do valor da química.
  const antes = sem(ultimaDoEddy);
  if (!(QUIMICA.test(antes) && /\b(quanto|valor)\b/.test(antes))) return null;
  if (PROCEDIMENTO.test(t) || NEGA.test(t)) return null;
  for (const tr of trechos) {
    const v = valorDoTrecho(tr);
    if (v != null) return v;
  }
  return null;
}

// O VALOR DO SINAL PARA TODOS OS SERVIÇOS, COMO O DONO DISSE.
//
// 10/10, PRODUÇÃO, William: "Todos os serviços, químicas, colorações,
// progressivas, selantes, luzes, cortes, escovas." (o R$ 50 ele tinha dito
// antes, e o Eddy repetiu na pergunta) e "o sinal deve ser feito para todo o
// serviço solicitado no mês de dezembro ... 50 reais". Só a química foi
// gravada; corte e escova ficaram sem sinal.
//
// Lê "todos os serviços / todo serviço / qualquer serviço" e o valor: na fala
// dele, ou -- se ele não repetiu -- o único valor em reais da pergunta que ele
// respondeu. Exceção ("todos menos manicure", "nem todos") ou dois valores
// diferentes: null, fica com o modelo.
const TODOS =
  /\b(todos? (os |o )?(servicos?|procedimentos?|atendimentos?)|qualquer (servico|procedimento|atendimento|horario)|todo (servico|procedimento|horario|agendamento)|todo o (servico|procedimento))\b/;
const EXCECAO =
  /\b(menos|exceto|fora (o|a|os|as)|nem todos?|nao (e |eh |vale )?(pra|para|em) todos?|so (pra|para|em|na|no|nas|nos) )/;
const DINHEIRO =
  /r\$\s*(\d{1,4}(?:,\d{1,2})?)(?!\d|,\d)|(?<!\d|\d,)(\d{1,4}(?:,\d{1,2})?)\s*(?:reais|real|conto|pila)\b/g;

function valoresEmReais(t: string): number[] {
  const achados = [...t.matchAll(DINHEIRO)].map((m) =>
    Number((m[1] ?? m[2] ?? '').replace(',', '.'))
  );
  return [...new Set(achados.filter((n) => n > 0))];
}

export function valorDeTodosDito(fala: string, ultimaDoEddy = ''): number | null {
  const t = sem(fala);
  if (!TODOS.test(t) || EXCECAO.test(t)) return null;
  const naFala = valoresEmReais(t);
  if (naFala.length === 0) {
    const doTrecho = t
      .split(/[;!?\n]|[.](?!\d)/)
      .map((x) => valorDoTrecho(` ${x.trim()} `))
      .filter((v): v is number => v != null);
    if (new Set(doTrecho).size === 1) return doTrecho[0]!;
    if (doTrecho.length > 1) return null;
  }
  if (naFala.length === 1) return naFala[0]!;
  if (naFala.length > 1) return null;
  const naPergunta = valoresEmReais(sem(ultimaDoEddy));
  return naPergunta.length === 1 ? naPergunta[0]! : null;
}
