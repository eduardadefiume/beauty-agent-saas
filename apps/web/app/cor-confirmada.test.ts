import { describe, expect, it } from 'vitest';

import { corConfirmada } from '../../../supabase/functions/eddy-agent/cor-confirmada';

const PADRAO = 'Pro resto da cor eu uso o padrão da maioria dos salões: ... Pode ser assim?';
const c = (unidade: string, valor: number, falaDoDono: string, ultimaDoEddy = '') =>
  corConfirmada({ unidade, valor, falaDoDono, ultimaDoEddy });

describe('responder_cor só grava o que ele disse (02/10)', () => {
  it('caso real: "oxe, já te expliquei no áudio" não confirma 2 níveis', () => {
    expect(c('NIVEIS', 2, 'oxe, ja te expliquei no audio de cor')).toBe(false);
    expect(c('SIM_NAO', 1, 'oxe, ja te expliquei no audio de cor')).toBe(false);
  });
  it.each([
    ['NIVEIS', 2, 'clareia até 2 tons'],
    ['NIVEIS', 3, 'a partir de três níveis eu faço teste'],
    ['MINUTOS', 30, 'meia hora por nível'],
    ['MINUTOS', 60, 'uma hora'],
    ['MINUTOS', 40, '40min'],
    ['REAIS', 0, 'não cobro a mais não'],
    ['REAIS', 0, 'tá incluso'],
    ['REAIS', 50, 'cobro 50'],
    ['REAIS', 49.9, 'R$ 49,90'],
    ['SIM_NAO', 1, 'sempre faço teste'],
    ['SIM_NAO', 0, 'não precisa'],
    ['MINUTOS', 30, 'pode ser', PADRAO],
    ['NIVEIS', 2, 'o resto faço o normal', PADRAO],
    ['REAIS', 0, 'isso mesmo', PADRAO],
  ])('grava: %s %s "%s"', (u, v, f, antes) => {
    expect(c(u as string, v as number, f as string, (antes as string) ?? '')).toBe(true);
  });
  it.each([
    ['NIVEIS', 2, 'ok'], // aceitou, mas não tinha padrão na mesa
    ['MINUTOS', 30, 'uns 40 min'],
    ['REAIS', 50, 'não cobro'],
    ['SIM_NAO', 1, 'não'],
    ['REAIS', 0, 'cobro 30'],
    ['NIVEIS', 3, 'pode ser', 'Quanto custa a matização?'],
  ])('não grava: %s %s "%s"', (u, v, f, antes) => {
    expect(c(u as string, v as number, f as string, (antes as string) ?? '')).toBe(false);
  });
});
