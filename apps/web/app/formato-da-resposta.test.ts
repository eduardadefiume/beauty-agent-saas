import { describe, expect, it } from 'vitest';

import { bolhasDaResposta } from '../../../supabase/functions/whatsapp-agent/formato-da-resposta';

// 07/10: o formato da ferramenta é a regra (3 bolhas + 1 pergunta).
describe('formato da resposta (07/10)', () => {
  it('caminho feliz: cumprimento sozinho + resposta + pergunta no fim', () => {
    expect(
      bolhasDaResposta({
        bolha1: 'Oi, Marina! Tudo bem?',
        bolha2: 'As luzes ficam R$ 450 e levam umas 4 horas.',
        bolha3: '',
        pergunta: 'Prefere terça ou quinta?',
      })
    ).toEqual(['Oi, Marina! Tudo bem?', 'As luzes ficam R$ 450 e levam umas 4 horas.\n\nPrefere terça ou quinta?']);
  });

  it('só pergunta', () => {
    expect(bolhasDaResposta({ bolha1: '', bolha2: '', bolha3: '', pergunta: 'Qual o seu nome?' })).toEqual([
      'Qual o seu nome?',
    ]);
  });

  it('sem pergunta (encerrando)', () => {
    expect(bolhasDaResposta({ bolha1: 'Marcado! Até terça.', bolha2: '', bolha3: '', pergunta: '' })).toEqual([
      'Marcado! Até terça.',
    ]);
  });

  it('três bolhas cheias + pergunta: nunca vira 4ª bolha', () => {
    const r = bolhasDaResposta({ bolha1: 'a', bolha2: 'b', bolha3: 'c', pergunta: 'd?' });
    expect(r).toHaveLength(3);
    expect(r[2]).toBe('c\n\nd?');
  });

  it('bolha do meio vazia não deixa buraco', () => {
    expect(bolhasDaResposta({ bolha1: 'a', bolha2: '  ', bolha3: 'c', pergunta: '' })).toEqual(['a', 'c']);
  });

  it('pergunta já escrita na bolha não duplica', () => {
    expect(
      bolhasDaResposta({ bolha1: 'Tenho terça. Prefere terça ou quinta?', pergunta: 'Prefere terça ou quinta?' })
    ).toEqual(['Tenho terça. Prefere terça ou quinta?']);
  });

  it('espaço sobrando é limpo', () => {
    expect(bolhasDaResposta({ bolha1: '  oi  ', pergunta: '  tudo bem?  ' })).toEqual(['oi\n\ntudo bem?']);
  });

  it('tudo vazio: nenhuma bolha (vira HANDOFF lá na frente)', () => {
    expect(bolhasDaResposta({ bolha1: '', bolha2: '', bolha3: '', pergunta: '' })).toEqual([]);
  });

  it('campo com tipo errado é ignorado, não quebra', () => {
    expect(bolhasDaResposta({ bolha1: 42, bolha2: null, bolha3: 'ok', pergunta: ['x'] })).toEqual(['ok']);
  });

  it('formato antigo (messages) continua lido', () => {
    expect(bolhasDaResposta({ messages: ['a', '', ' b '] })).toEqual(['a', 'b']);
  });

  it('formato antigo sem lista', () => {
    expect(bolhasDaResposta({ messages: 'oi' })).toEqual([]);
  });
});
