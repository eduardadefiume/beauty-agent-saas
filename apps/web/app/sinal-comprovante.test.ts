import { describe, expect, it } from 'vitest';

import { semConfirmarAntesDoDono } from '../../../supabase/functions/whatsapp-agent/sinal-comprovante';

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
