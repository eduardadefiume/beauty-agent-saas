import { describe, expect, it } from 'vitest';

import {
  eleaCitouOAgendamento,
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
