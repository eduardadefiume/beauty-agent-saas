// A trava que impede a conversa de morrer sem próximo passo.
//
// O caso que a originou está por inteiro no primeiro teste: a conversa real de
// 14/09, em que a cliente fez duas perguntas e recebeu uma resposta que não
// tinha nem pergunta, nem horário, nem agendamento.

import { describe, expect, it } from 'vitest';

import {
  condicaoComercialIgnorada,
  perguntasNaLeva,
  respostaSemProximoPasso,
  ultimaLevaDaCliente,
} from '../../../supabase/functions/whatsapp-agent/fecha-a-conversa';

const CONVERSA_REAL = {
  history: [
    { at: '2026-09-14T14:27:05+00:00', text: 'Quero assim, acho lindo', direction: 'INBOUND' },
    {
      at: '2026-09-14T14:27:36+00:00',
      text: 'Você acha que essa cor vai combinar comigo?',
      direction: 'INBOUND',
    },
    {
      at: '2026-09-14T14:27:36+00:00',
      text: 'Acha que da certo fazer no meu cabelo?',
      direction: 'INBOUND',
    },
  ],
};

const RESPOSTA_QUE_MORREU = [
  'Amei a referência!',
  'Isso quem confirma é o teste de mechas, que já entra junto com o procedimento. ' +
    'Realizamos o teste e dando tudo certo fazemos no mesmo dia.',
];

describe('a última leva da cliente', () => {
  it('pega as mensagens seguidas do fim, e só as dela', () => {
    expect(ultimaLevaDaCliente(CONVERSA_REAL)).toEqual([
      'Quero assim, acho lindo',
      'Você acha que essa cor vai combinar comigo?',
      'Acha que da certo fazer no meu cabelo?',
    ]);
  });

  it('para na primeira mensagem do agente: o que veio antes dela já foi respondido', () => {
    const leva = ultimaLevaDaCliente({
      history: [
        { text: 'quanto é luzes?', direction: 'INBOUND' },
        { text: 'Fica a partir de R$ 430,00', direction: 'OUTBOUND' },
        { text: 'e demora quanto?', direction: 'INBOUND' },
      ],
    });
    expect(leva).toEqual(['e demora quanto?']);
  });

  it('não quebra quando não há histórico', () => {
    expect(ultimaLevaDaCliente(null)).toEqual([]);
    expect(ultimaLevaDaCliente({})).toEqual([]);
    expect(ultimaLevaDaCliente({ history: 'nada disso' })).toEqual([]);
  });
});

describe('quantas perguntas ela fez', () => {
  it('conta uma por interrogação, inclusive duas na mesma mensagem', () => {
    expect(perguntasNaLeva(['tem horário hoje? e amanhã?'])).toBe(2);
  });

  it('leva sem pergunta nenhuma conta zero', () => {
    expect(perguntasNaLeva(['obrigada', 'até amanhã'])).toBe(0);
  });
});

describe('resposta sem próximo passo', () => {
  it('pega o caso real: duas perguntas, resposta sem horário e sem pergunta', () => {
    const leva = ultimaLevaDaCliente(CONVERSA_REAL);
    expect(respostaSemProximoPasso(RESPOSTA_QUE_MORREU, leva, false)).toBe(true);
  });

  it('deixa passar quando a resposta termina oferecendo horário', () => {
    const leva = ultimaLevaDaCliente(CONVERSA_REAL);
    const comFecho = [...RESPOSTA_QUE_MORREU, 'Tenho quinta 18/09 às 8h, pode ser?'];
    expect(respostaSemProximoPasso(comFecho, leva, false)).toBe(false);
  });

  it('deixa passar quando a resposta devolve uma pergunta', () => {
    const leva = ultimaLevaDaCliente(CONVERSA_REAL);
    const comPergunta = [...RESPOSTA_QUE_MORREU, 'Seu cabelo está quebrando nas pontas?'];
    expect(respostaSemProximoPasso(comPergunta, leva, false)).toBe(false);
  });

  it('deixa passar quando o agendamento acabou de ser fechado', () => {
    const leva = ultimaLevaDaCliente(CONVERSA_REAL);
    expect(respostaSemProximoPasso(['Marcado'], leva, true)).toBe(false);
  });

  it('não cobra fecho de quem só agradeceu: sem pergunta dela, sem cobrança', () => {
    const leva = ultimaLevaDaCliente({
      history: [{ text: 'obrigada, até amanhã!', direction: 'INBOUND' }],
    });
    expect(respostaSemProximoPasso(['Até amanhã!'], leva, false)).toBe(false);
  });

  it('reconhece horário em vários formatos', () => {
    const leva = ['tem horário?'];
    expect(respostaSemProximoPasso(['Tenho hoje às 14:30'], leva, false)).toBe(false);
    expect(respostaSemProximoPasso(['Tenho dia 30/08 às 8h'], leva, false)).toBe(false);
    expect(respostaSemProximoPasso(['Tenho amanhã às 9h30'], leva, false)).toBe(false);
  });

  it('o "Tudo bem?" do cumprimento NÃO conta como próximo passo', () => {
    // A conversa de 14/09 às 15:45, com a ficha em branco: o agente abriu com
    // "Oi, boa tarde! Tudo bem?", respondeu o preço e parou. A primeira versão
    // desta trava deixou passar porque havia um "?" na leva.
    const leva = ['Boa tarde', 'Gostaria de saber valor de luzes?'];
    const resposta = [
      'Oi, boa tarde! Tudo bem?',
      'O valor fica a partir de R$ 430,00, incluso hidratação e reconstrução',
      'Realizamos o teste de mechas e dando tudo certo fazemos o procedimento no mesmo dia',
    ];
    expect(respostaSemProximoPasso(resposta, leva, false)).toBe(true);
  });

  it('cumprimento seguido de pergunta de verdade continua passando', () => {
    const leva = ['Gostaria de saber valor de luzes?'];
    const resposta = ['Oi, boa tarde! Tudo bem?', 'Manda uma foto do seu cabelo hoje?'];
    expect(respostaSemProximoPasso(resposta, leva, false)).toBe(false);
  });

  it('reconhece as formas de cumprimento que o salão usa', () => {
    const leva = ['tem horário?'];
    for (const cumprimento of ['Oi! Tudo bem?', 'Olá, tudo bom?', 'Bom dia! Tudo bem?', 'Tudo bem?']) {
      expect(respostaSemProximoPasso([cumprimento, 'Fica R$ 430,00'], leva, false)).toBe(true);
    }
  });

  it('não confunde preço com horário', () => {
    const leva = ['quanto custa?'];
    expect(respostaSemProximoPasso(['Fica a partir de R$ 430,00'], leva, false)).toBe(true);
  });
});

describe('condição comercial ignorada', () => {
  // Conversa real de 14/09 às 16:32: duas perguntas na mesma leva, a de
  // horário respondida e a de parcelamento no chão.
  const LEVA_REAL = ['Terça não consigo, tem sexta depois do almoço?', 'Esse valor você dividi?'];

  it('pega o caso real: horário respondido, parcelamento ignorado', () => {
    expect(condicaoComercialIgnorada(['Tenho sexta, 18/09, às 13h, pode ser?'], LEVA_REAL, '')).toBe(
      true
    );
  });

  it('deixa passar quando a resposta fala do assunto', () => {
    const resposta = ['Tenho sexta, 18/09, às 13h, pode ser?', 'Sobre parcelar, aceitamos em 3x.'];
    expect(condicaoComercialIgnorada(resposta, LEVA_REAL, '')).toBe(false);
  });

  it('deixa passar quando a pergunta foi para a dona', () => {
    const paraDona = 'A cliente perguntou se pode parcelar o valor. Aceita?';
    expect(condicaoComercialIgnorada(['Tenho sexta às 13h, pode ser?'], LEVA_REAL, paraDona)).toBe(
      false
    );
  });

  it('não dispara quando ela não falou de dinheiro', () => {
    const leva = ['Tem horário na sexta?'];
    expect(condicaoComercialIgnorada(['Tenho sexta às 13h, pode ser?'], leva, '')).toBe(false);
  });

  it('reconhece as formas que as clientes usam', () => {
    for (const p of [
      'aceita cartão?',
      'pode ser no pix?',
      'dá desconto?',
      'tem que pagar sinal?',
      'qual a forma de pagamento?',
      'dá pra parcelar?',
    ]) {
      expect(condicaoComercialIgnorada(['Tenho sexta às 13h, pode ser?'], [p], '')).toBe(true);
    }
  });
});
