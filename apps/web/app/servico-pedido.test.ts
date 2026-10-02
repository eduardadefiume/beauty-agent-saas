import { describe, expect, it } from 'vitest';

import {
  eleaCitouOAgendamento,
  testeSemPedir,
  pediuOutroServico,
} from '../../../supabase/functions/whatsapp-agent/servico-pedido';

const CATALOGO = [
  'Luzes',
  'Teste de mecha',
  'Morena iluminada',
  'Corte com escova',
  'Corte',
  'Escova',
  'Progressiva',
  'Coloração',
];

describe('ela disse o nome do serviço (01/10, Luana)', () => {
  it('caso real: pediu luzes, ia marcar teste de mecha', () => {
    expect(pediuOutroServico(['pode sim, as luzes dia 3 às 9h'], 'Teste de mecha', CATALOGO)).toBe(
      'Luzes'
    );
  });
  it.each([
    [['quero a progressiva sexta'], 'Escova', 'Progressiva'],
    [['na vdd quero só o corte'], 'Corte com escova', 'Corte'],
    [['pode marcar a coloracao'], 'Luzes', 'Coloração'],
  ])('%j marcando %s -> %s', (leva, marcar, esperado) => {
    expect(pediuOutroServico(leva, marcar, CATALOGO)).toBe(esperado);
  });
  it.each([
    [['pode sim'], 'Teste de mecha'],
    [['isso, 9h'], 'Luzes'],
    [['pode marcar as luzes'], 'Luzes'],
    [['o teste de mecha das luzes pode ser dia 3'], 'Teste de mecha'],
    [['quero o corte com escova'], 'Corte com escova'],
    [['Morena Iluminada dia 5'], 'Morena iluminada'],
  ])('%j marcando %s -> passa', (leva, marcar) => {
    expect(pediuOutroServico(leva, marcar, CATALOGO)).toBeNull();
  });
});

describe('só desmarca o que ela citou (01/10, Marina)', () => {
  const FALAS = [
    'oi, vou ter que desmarcar as luzes do dia 1/12, surgiu uma viagem',
    'mas e o meu sinal de 100, vocês devolvem?',
  ];
  it('caso real: teste de mecha 07/10 não foi citado', () => {
    expect(eleaCitouOAgendamento(FALAS, 'Teste de mecha', '07/10 09:00')).toBe(false);
  });
  it('as luzes do dia 1/12 foram', () => {
    expect(eleaCitouOAgendamento(FALAS, 'Luzes', '01/12 09:00')).toBe(true);
  });
  it.each([
    [['desmarca o do dia 7'], 'Teste de mecha', '07/10 09:00', true],
    [['cancela o teste de mecha também'], 'Teste de mecha', '07/10 09:00', true],
    [['pode cancelar o de 07/10'], 'Teste de mecha', '07/10 09:00', true],
    [['cancela tudo do dia 17'], 'Teste de mecha', '07/10 09:00', false],
    [['quero cancelar'], 'Corte', '10/10 15:00', false],
  ])('%j / %s %s -> %s', (falas, servico, quando, esperado) => {
    expect(eleaCitouOAgendamento(falas, servico, quando)).toBe(esperado);
  });
});

describe('teste de mecha sozinho só se ela pediu (regra da Duda, 01/10)', () => {
  const PROCS = [
    'Luzes',
    'Morena iluminada',
    'Mechas',
    'Coloração',
    'Progressiva',
    'Teste de mecha',
  ];
  const T = 'Teste de mecha';
  it.each([
    'quero só o teste',
    'só o teste de mecha por enquanto',
    'apenas o teste',
    'so o teste',
    'quero fazer o teste primeiro',
    'dá pra fazer o teste antes?',
    'marca o teste de mecha',
    'testinho de mecha dia 3',
    'quero fazer o teste pra ver se meu cabelo aguenta, depois decido',
    'TESTE DE MECHAS dia 5',
    'teste de mexa dia 5',
    'quero fazer as luzes, mas só o teste primeiro',
  ])('MESMO_DIA, ela pediu só o teste: %s -> pode', (fala) => {
    expect(testeSemPedir([fala], T, 'MESMO_DIA', PROCS)).toBe(false);
  });

  it.each([
    'pode sim, as luzes dia 3 às 9h',
    'pode sim',
    'isso',
    'quero luzes',
    'teste e luzes no mesmo dia',
    'luzes com o teste',
    'não sei se meu cabelo aguenta',
    'o teste de mecha das luzes pode ser dia 3',
    'não quero só o teste, quero as luzes',
    'morena iluminada dia 4',
  ])('MESMO_DIA, não pediu só o teste: %s -> trava', (fala) => {
    expect(testeSemPedir([fala], T, 'MESMO_DIA', PROCS)).toBe(true);
  });

  it('ANTES: teste à parte é o normal', () => {
    expect(testeSemPedir(['pode sim, as luzes dia 3'], T, 'ANTES', PROCS)).toBe(false);
  });
  it('SEM_TESTE: nunca marca teste', () => {
    expect(testeSemPedir(['quero só o teste'], T, 'SEM_TESTE', PROCS)).toBe(true);
  });
  it.each(['Luzes', 'Corte', null])('serviço que não é teste (%s) nunca trava', (s) => {
    expect(testeSemPedir(['quero só o teste'], s, 'MESMO_DIA', PROCS)).toBe(false);
  });
  it('várias falas: pediu só o teste numa e "pode" na outra', () => {
    expect(testeSemPedir(['quero só o teste primeiro', 'pode, 9h'], T, 'MESMO_DIA', PROCS)).toBe(
      false
    );
  });
});

describe('plural e erro de digitação no nome do serviço (mesmo erro, outro lugar)', () => {
  const CAT = ['Luzes', 'Teste de mecha', 'Mechas', 'Corte', 'Escova'];
  it.each([
    [['quero o teste de mechas'], 'Teste de mecha'],
    [['TESTE DE MECHAS dia 5'], 'Teste de mecha'],
    [['quero fazer as mecha'], 'Mechas'],
    [['quero uma escovinha'], 'Escova'],
  ])('%j marcando %s -> passa', (leva, marcar) => {
    expect(pediuOutroServico(leva, marcar, CAT)).toBeNull();
  });
  it('quero mechas marcando teste -> Mechas', () => {
    expect(pediuOutroServico(['quero fazer mechas dia 3'], 'Teste de mecha', CAT)).toBe('Mechas');
  });
});

describe('cancelar: plural/singular também vale', () => {
  it.each([
    [['cancela as mecha'], 'Mechas', true],
    [['desmarca o teste de mechas'], 'Teste de mecha', true],
    [['cancela a luz'], 'Luzes', false],
  ])('%j / %s -> %s', (falas, servico, esperado) => {
    expect(eleaCitouOAgendamento(falas, servico, '20/12 09:00')).toBe(esperado);
  });
});
