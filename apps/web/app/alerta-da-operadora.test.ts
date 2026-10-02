import { describe, expect, it } from 'vitest';

import { alertaDoTurno } from '../../../supabase/functions/whatsapp-agent/alerta-da-operadora';

const base = {
  acaoDoModelo: 'REPLY' as const,
  acaoFinal: 'REPLY' as const,
  textos: ['Oi! Tenho terça às 14h, pode ser?'],
  precosSemBase: [] as string[],
  afirmouSemReserva: false,
  respostaQuebrada: false,
  conversa: 'final 7788',
};

// 02/10: a Duda quer saber no WhatsApp quando o modelo erra no teste do William.
describe('alerta da operadora (02/10)', () => {
  it('turno normal não avisa ninguém', () => {
    expect(alertaDoTurno(base)).toBeNull();
  });

  it('pergunta à dona bem escrita é o fluxo normal, não falha', () => {
    expect(
      alertaDoTurno({
        ...base,
        acaoDoModelo: 'ASK_OWNER',
        acaoFinal: 'ASK_OWNER',
        textos: [],
        perguntaAoDono: 'Gestante pode fazer hidratação?',
      })
    ).toBeNull();
  });

  it('preço sem base vira resposta bloqueada, com o valor e o texto', () => {
    const a = alertaDoTurno({ ...base, precosSemBase: ['R$ 450'], acaoFinal: 'ASK_OWNER' });
    expect(a?.tipo).toBe('RESPOSTA_BLOQUEADA');
    expect(a?.detalhe).toContain('R$ 450');
    expect(a?.detalhe).toContain('terça às 14h');
    expect(a?.detalhe).toContain('final 7788');
  });

  it('"agendei" sem reserva vira resposta bloqueada', () => {
    const a = alertaDoTurno({ ...base, afirmouSemReserva: true, acaoFinal: 'HANDOFF' });
    expect(a?.tipo).toBe('RESPOSTA_BLOQUEADA');
    expect(a?.detalhe).toContain('marcou');
  });

  it('duas travas no mesmo turno: UM alerta só, com as duas', () => {
    const a = alertaDoTurno({
      ...base,
      afirmouSemReserva: true,
      precosSemBase: ['R$ 300', 'R$ 90'],
      acaoFinal: 'HANDOFF',
    });
    expect(a?.tipo).toBe('RESPOSTA_BLOQUEADA');
    expect(a?.detalhe).toContain('marcou');
    expect(a?.detalhe).toContain('R$ 300, R$ 90');
  });

  it('resposta quebrada', () => {
    expect(alertaDoTurno({ ...base, respostaQuebrada: true, acaoFinal: 'HANDOFF' })?.tipo).toBe(
      'RESPOSTA_BLOQUEADA'
    );
  });

  it('REPLY vazio', () => {
    const a = alertaDoTurno({ ...base, textos: [], acaoFinal: 'HANDOFF' });
    expect(a?.detalhe).toContain('resposta vazia');
  });

  it('ASK_OWNER sem pergunta', () => {
    const a = alertaDoTurno({
      ...base,
      acaoDoModelo: 'ASK_OWNER',
      acaoFinal: 'HANDOFF',
      textos: [],
      perguntaAoDono: ' ',
    });
    expect(a?.tipo).toBe('RESPOSTA_BLOQUEADA');
    expect(a?.detalhe).toContain('sem escrever a pergunta');
  });

  it('HANDOFF do próprio modelo: passou para pessoa, com o motivo', () => {
    const a = alertaDoTurno({
      ...base,
      acaoDoModelo: 'HANDOFF',
      acaoFinal: 'HANDOFF',
      textos: [],
      motivo: 'cliente reclamou de alergia após a última química',
    });
    expect(a).toEqual({
      tipo: 'PASSOU_PARA_PESSOA',
      detalhe: 'cliente reclamou de alergia após a última química [conversa final 7788]',
    });
  });

  it('HANDOFF sem motivo ainda avisa', () => {
    const a = alertaDoTurno({ ...base, acaoDoModelo: 'HANDOFF', acaoFinal: 'HANDOFF', textos: [] });
    expect(a?.detalhe).toContain('sem motivo escrito');
  });

  it('texto enorme é cortado (cabe na linha do alerta)', () => {
    const a = alertaDoTurno({
      ...base,
      precosSemBase: ['R$ 1'],
      acaoFinal: 'ASK_OWNER',
      textos: ['x'.repeat(5000)],
    });
    expect(a!.detalhe.length).toBeLessThanOrEqual(780);
  });
});
