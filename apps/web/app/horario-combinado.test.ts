import { describe, expect, it } from 'vitest';

import type { Fala } from '../../../supabase/functions/whatsapp-agent/antes-do-horario';
import { horarioApareceuNaConversa } from '../../../supabase/functions/whatsapp-agent/horario-combinado';

const agente = (text: string): Fala => ({ direction: 'OUTBOUND', text });
const cliente = (text: string): Fala => ({ direction: 'INBOUND', text });

// Sabado 03/10/2026 09:00 em Sao Paulo = 12:00 UTC.
const SAB_9H = Date.UTC(2026, 9, 3, 12, 0);
const SAB_9H30 = Date.UTC(2026, 9, 3, 12, 30);
const SAB_12H = Date.UTC(2026, 9, 3, 15, 0);

describe('o horário que ela viu (30/09)', () => {
  it('caso real: ela pediu "sábado de manhã" e disse "Isso" para o serviço -- não viu 9h', () => {
    const conversa = [
      cliente('quanto ta o corte feminino ... e se tem horário sabado de manhã'),
      agente('O corte com escova está R$ 110,00. Qual o seu nome?'),
      cliente('Sou a Paula, quero só o corte'),
      agente('Prazer, Paula! Só confirmando: é o corte feminino com escova mesmo, R$ 110,00?'),
      cliente('Isso'),
    ];
    expect(horarioApareceuNaConversa(conversa, SAB_9H)).toBe(false);
  });

  it('oferecido por nós, em várias grafias', () => {
    for (const t of [
      'Tenho sábado às 9h, pode ser?',
      'sábado 09:00',
      'sábado 9h00',
      'às 9, pode?',
    ]) {
      expect(horarioApareceuNaConversa([agente(t)], SAB_9H)).toBe(true);
    }
  });

  it('pedido por ela', () => {
    expect(horarioApareceuNaConversa([cliente('pode ser 9 horas?')], SAB_9H)).toBe(true);
  });

  it('9h30 não é 9h, e 19h não é 9h', () => {
    expect(horarioApareceuNaConversa([agente('Tenho 9h30')], SAB_9H)).toBe(false);
    expect(horarioApareceuNaConversa([agente('Tenho 19h')], SAB_9H)).toBe(false);
    expect(horarioApareceuNaConversa([agente('Tenho 9h30')], SAB_9H30)).toBe(true);
  });

  it('meio-dia', () => {
    expect(horarioApareceuNaConversa([cliente('meio dia dá?')], SAB_12H)).toBe(true);
  });
});

describe('faixa não é escolha (30/09)', () => {
  // Sabado 10/10/2026 15:00 em Sao Paulo = 18:00 UTC.
  const SAB_15H = Date.UTC(2026, 9, 10, 18, 0);
  it('caso real: "dia 10 depois das 15h" + "Rê, já falei rs"', () => {
    const conversa = [
      cliente('Oi, sou a Rê. Queria corte com escova dia 10 depois das 15h'),
      agente('Oi, Rê! Tudo bem?'),
      agente('O corte com escova fica R$ 110,00.'),
      agente('Qual o seu nome?'),
      cliente('Rê, já falei rs'),
    ];
    expect(horarioApareceuNaConversa(conversa, SAB_15H)).toBe(false);
  });
  it('outras faixas', () => {
    for (const t of ['a partir das 15h', 'antes das 15h', 'após as 15', 'entre 14h e 16h']) {
      expect(horarioApareceuNaConversa([cliente(t)], SAB_15H)).toBe(false);
    }
  });
  it('mas "pode ser 15h" e "tenho 15h" continuam valendo', () => {
    expect(horarioApareceuNaConversa([cliente('pode ser 15h?')], SAB_15H)).toBe(true);
    expect(horarioApareceuNaConversa([agente('Tenho sábado às 15h, pode ser?')], SAB_15H)).toBe(
      true
    );
    expect(
      horarioApareceuNaConversa(
        [cliente('depois das 14h'), agente('Tenho sábado às 15h, pode ser?')],
        SAB_15H
      )
    ).toBe(true);
  });
});
