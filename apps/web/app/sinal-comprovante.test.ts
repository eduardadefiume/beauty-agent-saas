import { describe, expect, it } from 'vitest';

import {
  reservaPedeSinal,
  semConfirmarAntesDoDono,
} from '../../../supabase/functions/whatsapp-agent/sinal-comprovante';

const CERTO =
  'Recebi seu comprovante, obrigada! 💛 Já passei pro salão conferir e te aviso assim que confirmarem.';

describe('o comprovante não confirma antes do dono (01/10)', () => {
  it.each([
    [['Prontinho, Marina! Seu horário está confirmado 💛'], [CERTO]],
    [['Recebi! Tá confirmado sua luzes dia 01/12'], [CERTO]],
    [['Obrigada! Seu horário está garantido.'], [CERTO]],
    [
      ['Perfeito, agendado!', 'Qualquer coisa me chama'],
      [CERTO, 'Qualquer coisa me chama'],
    ],
  ])('%j vira o texto certo', (de, para) => {
    expect(semConfirmarAntesDoDono(de, CERTO)).toEqual(para);
  });

  it.each([
    [['Recebi seu comprovante! Já passei pro salão conferir e te aviso assim que confirmarem 💛']],
    [['Recebi, obrigada! Assim que o salão confirmar eu te aviso.']],
  ])('%j fica como está', (bolhas) => {
    expect(semConfirmarAntesDoDono(bolhas, CERTO)).toEqual(bolhas);
  });

  it('modelo não falou do comprovante: entra o texto certo antes da resposta dele', () => {
    expect(semConfirmarAntesDoDono(['Sobre a escova, fica R$ 80.'], CERTO)).toEqual([
      CERTO,
      'Sobre a escova, fica R$ 80.',
    ]);
  });
});

describe('crédito de sinal confirma a reserva nova (01/10)', () => {
  it.each([
    ['PENDING_SIGNAL', {}, true],
    ['PENDING_SIGNAL', { usado: true, jeito: 'USADO', confirmado: true }, false],
    ['PENDING_SIGNAL', { usado: true, jeito: 'USADO', confirmado: false }, true],
    ['CONFIRMED', { usado: true, jeito: 'ABATIDO_NO_DIA', confirmado: true }, false],
    ['CONFIRMED', {}, false],
  ])('%s %j -> cartão de sinal: %s', (status, credito, esperado) => {
    expect(reservaPedeSinal(status as string, credito)).toBe(esperado);
  });
});

describe('não duplica a frase do comprovante (01/10, Luana)', () => {
  it('modelo partiu a frase em dois balões', () => {
    const bolhas = [
      'Recebi seu comprovante, obrigada! Como o prazo do sinal tinha vencido, aquele horário foi liberado.',
      'Já passei pro salão conferir o seu Pix e, assim que confirmarem, te ajudo a garantir um horário de novo 💛',
    ];
    expect(semConfirmarAntesDoDono(bolhas, 'FRASE CERTA')).toEqual(bolhas);
  });
});
