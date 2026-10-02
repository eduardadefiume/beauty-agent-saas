import { describe, expect, it } from 'vitest';

import { comCacheNaUltima } from '../../../supabase/functions/whatsapp-agent/cache-da-volta';

describe('cache entre as voltas do mesmo turno (02/10, custo)', () => {
  it('turno com texto: vira bloco com marca, texto idêntico', () => {
    const r = comCacheNaUltima([{ role: 'user', content: 'CONTEXTO DO TURNO' }]);
    expect(r).toEqual([
      {
        role: 'user',
        content: [
          { type: 'text', text: 'CONTEXTO DO TURNO', cache_control: { type: 'ephemeral' } },
        ],
      },
    ]);
  });

  it('segunda volta: marca só no último tool_result, a primeira mensagem fica sem', () => {
    const v1 = comCacheNaUltima([{ role: 'user', content: 'CTX' }]);
    const historico = [
      { role: 'user', content: 'CTX' },
      {
        role: 'assistant',
        content: [
          { type: 'thinking', thinking: '' },
          { type: 'tool_use', id: 't1', name: 'x', input: {} },
        ],
      },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] },
    ];
    const v2 = comCacheNaUltima(historico);
    expect(v1[0].content).toHaveLength(1);
    expect(v2[0].content).toBe('CTX');
    expect(v2[1].content).toEqual(historico[1].content);
    expect(v2[2].content).toEqual([
      {
        type: 'tool_result',
        tool_use_id: 't1',
        content: 'ok',
        cache_control: { type: 'ephemeral' },
      },
    ]);
  });

  it('não muta o array original (o laço continua empurrando nele)', () => {
    const original = [{ role: 'user', content: [{ type: 'text', text: 'a' }] }];
    const copia = JSON.parse(JSON.stringify(original));
    comCacheNaUltima(original);
    expect(original).toEqual(copia);
  });

  it('nunca mais de uma marca nas mensagens, em qualquer volta', () => {
    let msgs: Array<{ role: string; content: unknown }> = [{ role: 'user', content: 'CTX' }];
    for (let v = 0; v < 8; v++) {
      msgs = comCacheNaUltima(msgs as never) as never;
      const marcas = JSON.stringify(msgs).split('cache_control').length - 1;
      expect(marcas).toBe(1);
      msgs.push({
        role: 'assistant',
        content: [{ type: 'tool_use', id: `t${v}`, name: 'x', input: {} }],
      });
      msgs.push({
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: `t${v}`, content: 'ok' }],
      });
    }
  });

  it('pula thinking no fim e aceita lista vazia / texto vazio', () => {
    expect(comCacheNaUltima([])).toEqual([]);
    expect(comCacheNaUltima([{ role: 'user', content: '' }])).toEqual([
      { role: 'user', content: '' },
    ]);
    const r = comCacheNaUltima([
      {
        role: 'user',
        content: [
          { type: 'text', text: 'a' },
          { type: 'thinking', thinking: '' },
        ],
      },
    ]);
    expect(r[0].content).toEqual([
      { type: 'text', text: 'a', cache_control: { type: 'ephemeral' } },
      { type: 'thinking', thinking: '' },
    ]);
  });
});
