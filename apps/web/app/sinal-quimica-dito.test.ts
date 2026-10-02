import { describe, expect, it } from 'vitest';

import { valorDaQuimicaDito } from '../../../supabase/functions/eddy-agent/sinal-quimica-dito';

// 02/10, DEV: "sinal sim mas só pra química" -> "50 reais. os outros não" e o
// Eddy disse "guardei" sem gravar. O código lê o valor da química e grava.
const PERGUNTA_QUIMICA = 'Show! E quanto você quer cobrar de sinal pra química?';
const PERGUNTA_GERAL =
  'Em quais procedimentos você quer cobrar sinal, e quanto em cada? Ex.: luzes R$ 100, corte não cobra.';

describe('valor do sinal da química, como o dono disse', () => {
  it('caso real do William', () => {
    expect(valorDaQuimicaDito('50 reais. os outros não', PERGUNTA_QUIMICA)).toBe(50);
  });

  it.each([
    ['sinal de 50 pra toda química', '', 50],
    ['sinal só pra química, 50 reais', '', 50],
    ['química 50, corte não', '', 50],
    ['R$ 80,00 nas químicas', '', 80],
    ['pras quimicas cobro 100', '', 100],
    ['cinquenta reais pra química', '', 50],
    ['cem reais em qualquer química', '', 100],
    ['50 pra química e 100 pras luzes', '', 50],
    ['luzes 100 e química 60', '', 60],
    ['R$50', PERGUNTA_QUIMICA, 50],
    ['50', PERGUNTA_QUIMICA, 50],
    ['uns 70 conto', PERGUNTA_QUIMICA, 70],
    ['quimica R$ 49,90', '', 49.9],
    ['química R$ 1.000', '', 1000],
    ['cento e cinquenta reais pra química', '', 150],
    ['Química: 50 reais.', '', 50],
    ['QUIMICA 50 REAIS', '', 50],
    ['química é 50 e corte não cobra', '', 50],
  ])('%s', (fala, antes, valor) => {
    expect(valorDaQuimicaDito(fala, antes)).toBe(valor);
  });

  it.each([
    ['sinal sim mas só pra química', ''], // sem valor ainda
    ['luzes 100, progressiva 50', ''], // por procedimento: é do modelo
    ['50 reais', PERGUNTA_GERAL], // pergunta não era da química
    ['50 reais', ''],
    ['cobro 50% na química', ''], // porcentagem não é valor fixo
    ['química não cobra sinal', ''],
    ['química com menos de 24h não devolve', ''],
    ['devolve se avisar com 48 horas', PERGUNTA_QUIMICA],
    ['a química leva 3 horas', ''],
    ['não quero cobrar sinal', PERGUNTA_QUIMICA],
    ['50 pra luzes', PERGUNTA_QUIMICA], // nomeou o procedimento
    ['oi', PERGUNTA_QUIMICA],
    ['', PERGUNTA_QUIMICA],
    ['quimica 0', ''],
  ])('não lê: %s', (fala, antes) => {
    expect(valorDaQuimicaDito(fala, antes)).toBeNull();
  });
});
