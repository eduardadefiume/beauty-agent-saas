import { describe, expect, it } from 'vitest';

import {
  fichaDita,
  quemMandaAFoto,
  quimicaPodeTerFormol,
} from '../../../supabase/functions/whatsapp-agent/ficha-dita';

describe('o que ela já contou do cabelo (01/10)', () => {
  it('caso real da Marina', () => {
    const f = fichaDita([
      'Oi! Sou a Marina, quero fazer luzes dia 5 de dezembro de manhã. Já fiz luzes aí ano passado',
    ]);
    expect(f.temQuimica).toBe(true);
    expect(f.quimicaQual).toBe('luzes');
    expect(f.quimicaHaQuantoTempo).toBe('ano passado');
  });

  it('química e tempo, vários jeitos', () => {
    const casos: Array<[string, Partial<ReturnType<typeof fichaDita>>]> = [
      [
        'fiz progressiva faz 6 meses',
        { temQuimica: true, quimicaQual: 'progressiva', quimicaHaQuantoTempo: 'faz 6 meses' },
      ],
      [
        'tenho mechas de uns 2 anos',
        { temQuimica: true, quimicaQual: 'mechas', quimicaHaQuantoTempo: 'uns 2 anos' },
      ],
      [
        'fiz selante mês passado',
        { temQuimica: true, quimicaQual: 'selante', quimicaHaQuantoTempo: 'mes passado' },
      ],
      [
        'fiz botox há 15 dias',
        { temQuimica: true, quimicaQual: 'botox', quimicaHaQuantoTempo: 'ha 15 dias' },
      ],
      ['tenho química sim, alisamento em março', { temQuimica: true, quimicaQual: 'alisamento' }],
      ['já fiz química', { temQuimica: true }],
      ['nunca fiz química', { temQuimica: false }],
      ['meu cabelo é virgem', { temQuimica: false }],
      ['não tenho química nenhuma', { temQuimica: false }],
    ];
    for (const [texto, esperado] of casos) {
      expect(fichaDita([texto]), texto).toMatchObject(esperado);
    }
  });

  it('"nem progressiva" não vira progressiva', () => {
    const f = fichaDita([
      'Só as luzes do ano passado, não tenho coloração nem progressiva. Quero um loiro mel',
    ]);
    expect(f.quimicaQual).toBe('luzes');
    expect(f.temColoracao).toBe(false);
    expect(f.quimicaHaQuantoTempo).toBe('ano passado');
  });

  it('coloração', () => {
    expect(fichaDita(['pinto todo mês']).temColoracao).toBe(true);
    expect(fichaDita(['nunca pintei']).temColoracao).toBe(false);
    expect(fichaDita(['não pinto o cabelo']).temColoracao).toBe(false);
    expect(fichaDita(['tenho tintura castanha']).temColoracao).toBe(true);
  });

  it('tempo só quando fala da química ou responde a pergunta do tempo', () => {
    expect(fichaDita(['quero marcar pra semana que vem']).quimicaHaQuantoTempo).toBeUndefined();
    expect(
      fichaDita(['faz 1 ano mais ou menos'], 'Faz quanto tempo que você fez essa química?')
        .quimicaHaQuantoTempo
    ).toBe('faz 1 ano mais ou menos');
    expect(fichaDita(['faz 1 ano mais ou menos']).quimicaHaQuantoTempo).toBeUndefined();
  });

  it('não inventa', () => {
    expect(fichaDita(['quero fazer luzes'])).toMatchObject({
      temQuimica: true,
      quimicaQual: 'luzes',
    });
    expect(fichaDita(['oi tudo bem?'])).toEqual({});
    expect(fichaDita(['quanto custa a progressiva?']).quimicaHaQuantoTempo).toBeUndefined();
  });
});

describe('formol só para alisamento', () => {
  it.each([
    ['luzes', false],
    ['mechas', false],
    ['descoloração', false],
    ['morena iluminada', false],
    ['luzes, mechas', false],
    ['progressiva', true],
    ['selante', true],
    ['botox', true],
    ['alisamento', true],
    ['luzes, progressiva', true],
    ['', true],
    [null, true],
  ])('%s -> %s', (qual, esperado) => {
    expect(quimicaPodeTerFormol(qual as string | null)).toBe(esperado);
  });
});

describe('quem manda a foto é ela', () => {
  it.each([
    [
      'Já te mando uma foto desse tom pra eu ter certeza do que você quer?',
      'Me manda uma foto desse tom pra eu ter certeza do que você quer?',
    ],
    ['Te mando uma foto do tom?', 'Me manda uma foto do tom?'],
    ['Perfeito! Já te mando uma foto do seu cabelo?', 'Perfeito! Me manda uma foto do seu cabelo?'],
    ['Vou te mandar umas fotos de referência?', 'Me manda umas fotos de referência?'],
    ['Me manda uma foto do tom?', 'Me manda uma foto do tom?'],
    ['Recebi a foto, obrigada!', 'Recebi a foto, obrigada!'],
  ])('%s', (de, para) => {
    expect(quemMandaAFoto(de)).toBe(para);
  });
});

describe('o tempo acaba onde começa o pedido', () => {
  it.each([
    ['fiz progressiva faz 6 meses e quero marcar dia 5', 'faz 6 meses'],
    ['fiz luzes faz um ano e meio', 'faz um ano e meio'],
    ['fiz selante há 3 meses mas tá caindo', 'ha 3 meses'],
  ])('%s', (fala, tempo) => {
    expect(fichaDita([fala]).quimicaHaQuantoTempo).toBe(tempo);
  });
});
