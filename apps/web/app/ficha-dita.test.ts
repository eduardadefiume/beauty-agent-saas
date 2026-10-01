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
    expect(fichaDita(['oi tudo bem?'])).toEqual({});
    expect(fichaDita(['quanto custa a progressiva?'])).toEqual({});
  });
});

describe('o que ela QUER não é o que ela TEM (falhou ao vivo em 01/10)', () => {
  it('Paty: quer progressiva, nunca fez química', () => {
    const f = fichaDita([
      'Oi, aqui é a Paty. Quero fazer progressiva, nunca fiz química, quanto fica?',
    ]);
    expect(f.temQuimica).toBe(false);
    expect(f.quimicaQual).toBeUndefined();
  });

  it('Gabi: quer morena iluminada, tem progressiva, pinta', () => {
    const f = fichaDita([
      'oi sou a Gabi, quero morena iluminada. fiz progressiva faz uns 8 meses e pinto o cabelo de castanho',
    ]);
    expect(f.temQuimica).toBe(true);
    expect(f.quimicaQual).toBe('progressiva');
    expect(f.quimicaHaQuantoTempo).toBe('faz uns 8 meses');
    expect(f.temColoracao).toBe(true);
  });

  it('Luana: quer luzes, já fez luzes, sem coloração nem progressiva', () => {
    const f = fichaDita([
      'Oi! Sou a Luana, quero fazer luzes dia 3 de dezembro de manhã. Já fiz luzes ano passado, não tenho coloração nem progressiva',
    ]);
    expect(f).toEqual({
      temQuimica: true,
      quimicaQual: 'luzes',
      quimicaHaQuantoTempo: 'ano passado',
      temColoracao: false,
    });
  });

  it.each([
    ['quero fazer luzes', {}],
    ['queria saber o valor da progressiva', {}],
    ['gostaria de fazer mechas em dezembro', {}],
    ['quanto fica um botox?', {}],
    [
      'quero fazer progressiva de novo, fiz uma faz 4 meses',
      { temQuimica: true, quimicaQual: 'progressiva', quimicaHaQuantoTempo: 'faz 4 meses' },
    ],
    ['tenho mechas e quero retocar', { temQuimica: true, quimicaQual: 'mechas' }],
    ['quero luzes mas tenho progressiva', { temQuimica: true, quimicaQual: 'progressiva' }],
    ['nunca fiz progressiva, quero fazer', {}],
    ['sem química, só quero luzes', { temQuimica: false }],
    ['quero retocar minhas luzes', { temQuimica: true, quimicaQual: 'luzes' }],
    ['quero marcar mechas em janeiro', {}],
    ['fiz mechas em janeiro', { temQuimica: true, quimicaQual: 'mechas' }],
    ['tenho progressiva há 1 ano e meio', { temQuimica: true, quimicaHaQuantoTempo: 'ha 1 ano e meio' }],
  ])('%s', (fala, esperado) => {
    const f = fichaDita([fala]);
    for (const [k, v] of Object.entries(esperado))
      expect(f[k as keyof typeof f], `${fala} ${k}`).toEqual(v);
    if (Object.keys(esperado).length === 0) expect(f.temQuimica, fala).toBeUndefined();
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
