// PRECO QUE SAI DAQUI PRECISA TER LASTRO NOS DADOS DO SALAO.
//
// O prompt ja manda: "preco que voce nao achou em NENHUMA das tres fontes nao
// pode ser estimado, nem citado como faixa". Regra de prompt e a defesa certa
// para comportamento, e falha do jeito que modelo falha: nas vezes em que ela
// nao vale, ninguem fica sabendo.
//
// E preco errado nao e alucinacao comum. E um numero real, plausivel, que a
// cliente le na tela, anota, e cobra do salao na cadeira. O salao honra ou
// desmente na frente dela. As duas saidas custam dinheiro e custam a cliente.
//
// Por isso aqui e codigo, e nao mais uma linha de prompt: todo valor em reais
// que o agente escrever precisa aparecer em algum lugar dos dados daquela
// conversa. Nao e o modelo que julga se sabe o preco; e a busca que diz se o
// numero existe. Mesma forma da trava de agendamento, que ja mora no index.ts.
//
// O QUE CONTA COMO LASTRO. As tres fontes que o prompt nomeia, mais duas que
// tambem sao a voz do salao:
//   - catalog[].priceMinor .... o preco cadastrado, a fonte boa
//   - statusArts .............. a arte que o salao publicou, com o que esta escrita nela
//   - policies ................ regra escrita do negocio
//   - ownerAnswers ............ a dona respondendo, nesta conversa
//   - client.lastVisits ....... o que ELA pagou da outra vez
//
// O que NAO conta: o que a cliente escreveu. "Me falaram que era 300" nao vira
// permissao para o agente confirmar 300.
//
// SOMA NAO PASSA, E ISSO E DE PROPOSITO. Corte 120 + escova 80 e o agente
// escrevendo "fica R$ 200": 20000 nao esta em lugar nenhum, entao a trava pega.
// Nao e um efeito colateral - o proprio prompt proibe preco "comparado com
// outro servico". Pacote e condicao comercial: quem fecha e a dona.

export type ValorSemLastro = {
  /** O valor em centavos, do jeito que saiu do texto. */
  centavos: number;
  /** O pedaco de texto que o produziu, para o log e para a tela da equipe. */
  trecho: string;
};

// Duas formas de escrever dinheiro em portugues: com o simbolo na frente, ou
// com a palavra atras. Exigir uma das duas e o que separa preco de horario
// ("14:30"), de telefone e de quantidade ("3 sessoes").
const DINHEIRO = /R\$\s*([\d.,]+)|([\d.,]+)\s*(?:reais|real)\b/gi;

/**
 * Le um numero escrito em portugues e devolve centavos.
 *
 * O ponto e ambiguo em portugues so na aparencia: separador de milhar vem
 * sempre com tres digitos atras ("1.250"), decimal vem com um ou dois
 * ("430.50"). Contar os digitos resolve sem chute.
 *
 * Devolve null para o que nao da para ler com certeza. Numero ilegivel nao
 * vira acusacao: nao da para dizer que esta errado o que nao da para ler.
 */
export function centavosDoTexto(bruto: string): number | null {
  const texto = bruto.trim();
  if (texto.length === 0) return null;

  if (texto.includes(',')) {
    const ultima = texto.lastIndexOf(',');
    const inteiro = texto.slice(0, ultima).replaceAll('.', '');
    const fracao = texto.slice(ultima + 1);
    if (!/^\d+$/.test(inteiro) || !/^\d{1,2}$/.test(fracao)) return null;
    return Number(inteiro) * 100 + Number(fracao.padEnd(2, '0'));
  }

  if (/^\d{1,3}(\.\d{3})+$/.test(texto)) {
    return Number(texto.replaceAll('.', '')) * 100;
  }

  const decimal = /^(\d+)\.(\d{1,2})$/.exec(texto);
  if (decimal) {
    return Number(decimal[1]) * 100 + Number(decimal[2]!.padEnd(2, '0'));
  }

  if (/^\d+$/.test(texto)) return Number(texto) * 100;

  return null;
}

/** Todo valor em reais que aparece num texto qualquer, em centavos. */
export function valoresEmCentavos(texto: string): ValorSemLastro[] {
  const achados: ValorSemLastro[] = [];
  for (const encontro of texto.matchAll(DINHEIRO)) {
    const numero = encontro[1] ?? encontro[2] ?? '';
    const centavos = centavosDoTexto(numero);
    if (centavos == null) continue;
    achados.push({ centavos, trecho: encontro[0].trim() });
  }
  return achados;
}

function inteiroOuNada(valor: unknown): number | null {
  if (typeof valor === 'number' && Number.isFinite(valor)) return Math.round(valor);
  if (typeof valor === 'string' && /^-?\d+$/.test(valor.trim())) return Number(valor.trim());
  return null;
}

/**
 * O conjunto de precos que este negocio pode dizer nesta conversa, em centavos.
 *
 * Os blocos de texto (artes, policies, respostas da dona) entram inteiros:
 * varrer o JSON serializado pega o valor esteja ele no corpo da arte, no
 * `ownerNote` ou no meio de uma regra escrita, sem precisar saber de antemao
 * em que campo o salao escreveu.
 */
export function precosDoNegocio(estavel: unknown, volatil: unknown): Set<number> {
  const conhecidos = new Set<number>();
  const e = (estavel ?? {}) as Record<string, unknown>;
  const v = (volatil ?? {}) as Record<string, unknown>;

  for (const servico of Array.isArray(e.catalog) ? e.catalog : []) {
    const preco = inteiroOuNada((servico as Record<string, unknown>)?.priceMinor);
    if (preco != null) conhecidos.add(preco);
  }

  const cliente = (v.client ?? {}) as Record<string, unknown>;
  for (const visita of Array.isArray(cliente.lastVisits) ? cliente.lastVisits : []) {
    const pago = inteiroOuNada((visita as Record<string, unknown>)?.amountMinor);
    if (pago != null) conhecidos.add(pago);
  }

  for (const bloco of [e.statusArts, e.policies, v.ownerAnswers]) {
    if (bloco == null) continue;
    for (const achado of valoresEmCentavos(JSON.stringify(bloco))) {
      conhecidos.add(achado.centavos);
    }
  }

  return conhecidos;
}

/**
 * Os valores que o agente escreveu e que nao tem lastro nenhum nos dados.
 *
 * Lista vazia quer dizer que pode enviar. Qualquer item quer dizer que aquele
 * numero nasceu no modelo, e nao no salao.
 */
export function precosSemLastro(textos: string[], conhecidos: Set<number>): ValorSemLastro[] {
  const soltos: ValorSemLastro[] = [];
  for (const texto of textos) {
    for (const achado of valoresEmCentavos(texto)) {
      if (!conhecidos.has(achado.centavos)) soltos.push(achado);
    }
  }
  return soltos;
}
