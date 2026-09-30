import { describe, expect, it } from 'vitest';

import { nomeDito } from '../../../supabase/functions/whatsapp-agent/nome-dito';

describe('o nome que ela já disse (30/09)', () => {
  it('caso real', () => {
    expect(nomeDito(['Oi, sou a Rê. Queria corte com escova dia 10 depois das 15h'])).toBe('Rê');
  });
  it('outras formas', () => {
    expect(nomeDito(['Meu nome é Ana Paula'])).toBe('Ana Paula');
    expect(nomeDito(['oi aqui é a Carla'])).toBe('Carla');
    expect(nomeDito(['me chamo Júlia, quero escova'])).toBe('Júlia');
    expect(nomeDito(['Oi, sou a Carla! Quero fazer corte'])).toBe('Carla');
  });
  it('não inventa', () => {
    expect(nomeDito(['sou a cliente de ontem'])).toBeNull();
    expect(nomeDito(['sou a mãe da Bia'])).toBeNull();
    expect(nomeDito(['quero corte sábado'])).toBeNull();
    expect(nomeDito(['sou alérgica a formol'])).toBeNull();
  });
});
