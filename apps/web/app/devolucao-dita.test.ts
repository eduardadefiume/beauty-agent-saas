import { describe, expect, it } from 'vitest';

import { devolucaoDita } from '../../../supabase/functions/eddy-agent/devolucao-dita';

describe('a regra de devolução do sinal como o dono disse (02/10, William)', () => {
  it.each([
    ['sinal sim mas só pra quimica. e se desmarcar com menos de 24h não devolve', true, 24],
    ['com menos de 48 horas não devolve', true, 48],
    ['se cancelar com menos de 1 dia perde o sinal', true, 24],
    ['menos de dois dias não tem devolução', true, 48],
    ['devolve se avisar com 48h', true, 48],
    ['avisando 2 dias antes eu devolvo', true, 48],
    ['com mais de 24 horas eu devolvo o sinal', true, 24],
    ['devolvo se avisar uma semana antes', true, 168],
    ['reembolso só com 72hs de antecedência', true, 72],
    ['não devolve', false, null],
    ['o sinal não volta', false, null],
    ['não tem devolução não', false, null],
    ['desmarcou perdeu', false, null],
    ['nunca devolvo sinal', false, null],
    ['devolvo sempre', true, 0],
  ])('%s -> devolve=%s, %s h', (fala, devolve, ateHoras) => {
    expect(devolucaoDita(fala)).toEqual({ devolve, ateHoras });
  });

  it.each([
    'quero cobrar 50 de sinal',
    'o pix é 16 99999-0000',
    'sinal sim mas só pra quimica',
    'oi tudo bem',
  ])('não fala de devolução: %s -> null', (fala) => {
    expect(devolucaoDita(fala)).toBeNull();
  });
});
