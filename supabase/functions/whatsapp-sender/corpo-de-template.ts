// O CORPO DO TEMPLATE.
//
// 23/09/2026. A tabela `outbox_messages` nasceu em 20/08 com `template_name`,
// `template_language` e `template_params`, e as tres colunas nunca receberam
// uma linha porque o worker nunca soube monta-las. Era o unico jeito de falar
// com uma cliente fora da janela de 24h -- ou seja, o lembrete de vespera
// inteiro dependia destas linhas.
//
// Mora em arquivo proprio, e nao dentro do index.ts, pelo mesmo motivo de
// `resposta-limpa.ts`: o index chama `Deno.serve` no topo, entao quem o importa
// para testar sobe um servidor. Regra que decide mensagem tem que ser testavel
// sem subir nada.

// A forma que a Meta espera:
//   { type: 'template', template: { name, language: { code }, components } }
export type EntradaDeTemplate = {
  template_name: string | null;
  template_language: string | null;
  template_params: unknown;
};

// `pt_BR` e o padrao da casa. Quem manda e a coluna: modelo aprovado num
// idioma e enviado com o codigo de outro volta como "template not found", que
// e um erro que nao parece ser sobre idioma.
const IDIOMA_PADRAO = 'pt_BR';

/**
 * Monta o corpo de uma mensagem de template para a Cloud API.
 *
 * TRES RECUSAS DA META QUE NAO VEM COM EXPLICACAO UTIL, e por isso sao tratadas
 * aqui em vez de virarem um 131008 no log:
 *
 * 1. Parametro com quebra de linha, tabulacao ou quatro espacos seguidos e
 *    recusado. Nome de cliente vem de dado digitado por gente, entao vem com
 *    espaco duplo mais vezes do que se imagina.
 * 2. Parametro vazio derruba a mensagem inteira, nao so aquele campo.
 * 3. Modelo sem variavel nao pode levar `components`. Lista vazia e recusada.
 *
 * A contagem de parametros nao e checada aqui: quem checa e o banco, no
 * enqueue, onde da para dizer qual modelo era e quantos ele esperava.
 */
export function corpoDeTemplate(item: EntradaDeTemplate): Record<string, unknown> {
  const nome = (item.template_name ?? '').trim();
  if (!nome) {
    throw new Error('mensagem de template sem nome de modelo');
  }

  const idioma = (item.template_language ?? '').trim() || IDIOMA_PADRAO;

  const brutos = Array.isArray(item.template_params) ? item.template_params : [];
  const parametros = brutos.map((valor, i) => {
    const texto = String(valor ?? '')
      .replace(/\s+/g, ' ')
      .trim();
    if (texto.length === 0) {
      throw new Error(`parametro ${i + 1} do template ${nome} veio vazio`);
    }
    return { type: 'text', text: texto };
  });

  const template: Record<string, unknown> = {
    name: nome,
    language: { code: idioma },
  };
  if (parametros.length > 0) {
    template.components = [{ type: 'body', parameters: parametros }];
  }

  return { type: 'template', template };
}
