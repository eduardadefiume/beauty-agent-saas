import { describe, expect, it } from 'vitest';

import {
  valorDaQuimicaDito,
  valorDeTodosDito,
} from '../../../supabase/functions/eddy-agent/sinal-quimica-dito';

const PERGUNTA_DO_EDDY =
  'Sobre o sinal: você disse R$ 50, mas é pra todo serviço marcado em dezembro ou só pra alguns (tipo química)? Me diz quais procedimentos entram e o valor de cada um.';

// 10/10, PRODUÇÃO, William: só a química foi gravada; corte e escova sem sinal.
describe('sinal para todos os serviços (10/10, William)', () => {
  it('resposta real: "Todos os serviços, químicas, ..., cortes, escovas." -> 50 (da pergunta)', () => {
    expect(
      valorDeTodosDito(
        'Todos os serviços, químicas, colorações, progressivas, selantes, luzes, cortes, escovas.',
        PERGUNTA_DO_EDDY
      )
    ).toBe(50);
  });

  it('mensagem real: "todo o serviço solicitado ... 50 reais" (com a chave Pix no meio) -> 50', () => {
    expect(
      valorDeTodosDito(
        'O sinal deve ser feito para todo o serviço solicitado no mês de dezembro, qualquer horário agendado no mês de dezembro, esse número de celular é a chave do Pix:16991319581 onde deve ser feito a transferência do valor de reserva de 50 reais'
      )
    ).toBe(50);
  });

  it('"Corte entra também todos os serviços" depois de "sinal de R$ 50 pra química" -> 50', () => {
    expect(
      valorDeTodosDito(
        'Corte entra também todos os serviços',
        'Entendi: sinal de R$ 50 pra todo tipo de química (luzes, coloração, progressiva, selante). Corte e escova não entram, se for diferente me fala.'
      )
    ).toBe(50);
  });

  it.each([
    ['sinal de 50 em todos os serviços', 50],
    ['R$ 80 pra qualquer serviço', 80],
    ['todo procedimento paga 30 reais de sinal', 30],
    ['todos os procedimentos, cinquenta reais', 50],
    ['vale pra todos os atendimentos, r$ 45,50', 45.5],
    ['TODOS OS SERVIÇOS 100 REAIS', 100],
  ])('"%s" -> %s', (fala, valor) => {
    expect(valorDeTodosDito(fala)).toBe(valor);
  });

  it.each([
    ['todos os serviços menos manicure, 50 reais', 'exceção fica com o modelo'],
    ['todos exceto escova R$ 50', 'exceção'],
    ['nem todos os serviços, só química 50', 'nem todos'],
    ['não é pra todos os serviços', 'negação'],
    ['só pra química 50 reais', 'só química não é todos'],
    ['todos os serviços: corte 30 reais e química 100 reais', 'dois valores'],
    ['todos os serviços', 'sem valor e sem pergunta'],
    ['quero cobrar 50 de sinal', 'não falou de todos'],
    ['todos os serviços levam 2 horas', 'hora não é dinheiro'],
    ['', 'vazio'],
  ])('"%s" -> null (%s)', (fala) => {
    expect(valorDeTodosDito(fala, 'Qual o valor do sinal?')).toBeNull();
  });

  it('pergunta com dois valores não decide', () => {
    expect(
      valorDeTodosDito(
        'todos os serviços',
        'Hoje está R$ 50 na química e R$ 30 no corte. Vale pra todos?'
      )
    ).toBeNull();
  });

  it('a leitura da química continua a mesma na resposta real (não força química)', () => {
    expect(
      valorDaQuimicaDito(
        'Todos os serviços, químicas, colorações, progressivas, selantes, luzes, cortes, escovas.',
        PERGUNTA_DO_EDDY
      )
    ).toBeNull();
  });
});
