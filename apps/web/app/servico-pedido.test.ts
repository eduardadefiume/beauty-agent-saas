import { describe, expect, it } from 'vitest';

import { pediuOutroServico } from '../../../supabase/functions/whatsapp-agent/servico-pedido';

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
