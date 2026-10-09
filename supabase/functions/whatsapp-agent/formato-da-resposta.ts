// O FORMATO DA RESPOSTA É A REGRA (07/10/2026).
//
// Até aqui a atendente devolvia `messages: string[]` livre, e o código
// consertava depois: cortava a 2ª pergunta (uma-pergunta.ts), juntava a 4ª
// bolha na 3ª (ateTresBolhas). Remendo em cima da saída. Agora a ferramenta
// `atender` só TEM três campos de bolha e UM campo de pergunta: não existe
// onde escrever a 4ª bolha nem a 2ª pergunta. (O modo estrito da API não
// aceita maxItems em lista; campos fixos são o jeito de o formato garantir.)
//
// A pergunta sai por último, no fim da última bolha com texto: é a última
// coisa que a cliente lê, e um "sim" dela responde exatamente a ela.

export type FormatoDaResposta = {
  bolha1?: unknown;
  bolha2?: unknown;
  bolha3?: unknown;
  pergunta?: unknown;
  // Formato antigo: histórico, chamadas em andamento durante o deploy.
  messages?: unknown;
};

const texto = (x: unknown) => (typeof x === 'string' ? x.trim() : '');

export function bolhasDaResposta(r: FormatoDaResposta): string[] {
  const temCampoNovo = ['bolha1', 'bolha2', 'bolha3', 'pergunta'].some((k) => k in r);
  if (!temCampoNovo) {
    return Array.isArray(r.messages) ? r.messages.map(texto).filter(Boolean) : [];
  }
  const bolhas = [texto(r.bolha1), texto(r.bolha2), texto(r.bolha3)].filter(Boolean);
  const pergunta = texto(r.pergunta);
  if (!pergunta) return bolhas;
  if (bolhas.length === 0) return [pergunta];
  const ultima = bolhas[bolhas.length - 1] ?? '';
  // A pergunta repetida na bolha (o modelo escreveu nos dois lugares) não dobra.
  if (ultima.includes(pergunta)) return bolhas;
  bolhas[bolhas.length - 1] = ultima + '\n\n' + pergunta;
  return bolhas;
}
