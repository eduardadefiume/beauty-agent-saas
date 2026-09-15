// A trava do procedimento. Os dois casos reais estão inteiros aqui: a conversa
// de 14/09 à noite (horário de um serviço que ela nunca escolheu) e a de 15/09
// de manhã (o agente afirmando "sua coloração" e depois escolhendo sozinho
// UMA das cinco progressivas do catálogo).

import { describe, expect, it } from 'vitest';

import {
  afirmaServico,
  escolhaDaCliente,
  type Fala,
  falasDaCliente,
  falasDoAgente,
  mencionaServico,
  ofereceHorario,
  palavrasDoServico,
  precoFoiDito,
  servicoFoiDito,
  servicosQueCabem,
  travaDoProcedimento,
} from '../../../supabase/functions/whatsapp-agent/antes-do-horario';

const agente = (text: string): Fala => ({ direction: 'OUTBOUND', text });
const cliente = (text: string): Fala => ({ direction: 'INBOUND', text });

// O catálogo do salão-piloto, com os nomes que importam para estes casos.
// Cinco progressivas, todas R$ 200, e três mechas.
const CATALOGO = [
  'Botox capilar',
  'Coloração',
  'Corte',
  'Hidratação',
  'Mechas loiras — teste na semana',
  'Mechas loiras — teste no mesmo dia',
  'Mechas morena iluminada',
  'Progressiva 3D',
  'Progressiva 4D',
  'Progressiva com formol',
  'Progressiva japonesa',
  'Progressiva sem formol',
  'Selante com formol',
  'Selante sem formol',
];

// 14/09: oito perguntas sobre química e nenhuma dizendo o que ele ia marcar.
const NOITE_DE_14 = [
  agente('Oi, boa noite! Tudo bem?'),
  cliente('Oi, gostaria de marcar um procedimento'),
  agente('Qual o seu nome?'),
  cliente('Rayana'),
  agente('Me manda uma foto do seu cabelo hoje, como ele está?'),
  agente('Você já fez alguma química no cabelo, Rayana?'),
  cliente('Pinto o cabelo todo mês'),
  agente('Além da pintura, você já fez alguma química, tipo progressiva ou alisamento?'),
  cliente('Já fiz progressiva'),
  agente('Faz quanto tempo que você fez essa química, Rayana?'),
  cliente('Faz um mês'),
  agente('Você sabe se essa química tinha formol?'),
  cliente('Sim tinha formol'),
];

// 15/09 de manhã, até o "Não é coloração".
const MANHA_DE_15 = [
  ...NOITE_DE_14,
  agente('Perfeito, Rayana!'),
  agente('Tenho amanhã, terça, às 13h, pode ser?'),
  cliente('Bom dia'),
  agente('Bom dia, Rayana! Tudo bem?'),
  agente('Tenho hoje às 13h para sua coloração, pode ser?'),
  cliente('Tudo bem?!'),
  cliente('Olá bom dia'),
  agente('Tudo ótimo, e com você?'),
  agente('A coloração está R$ 160,00.'),
  agente('Tenho hoje às 13h, pode ser?'),
  cliente('Não quero agendar, obrigada'),
  agente('Tudo bem, Rayana! Qualquer coisa é só chamar.'),
  cliente('Olá'),
  cliente('Tudo bem?'),
  agente('Tudo bem, Rayana! E você?'),
  cliente('Tudo ótimo'),
  cliente('Gostaria de marcar um procedimento'),
  agente('Tenho hoje às 13h para a coloração, pode ser?'),
  cliente('Não é coloração'),
  agente('Então me conta, o que você quer fazer no cabelo?'),
  cliente('Eu gostaria de fazer uma progressiva'),
];

describe('as palavras que identificam um serviço', () => {
  it('descarta conectivo, palavra genérica e verbo de pedido', () => {
    expect(palavrasDoServico('Mechas morena iluminada')).toEqual([
      'mechas',
      'morena',
      'iluminada',
    ]);
    expect(palavrasDoServico('Mechas loiras — teste no mesmo dia')).toEqual(['mechas', 'loiras']);
    expect(palavrasDoServico('Progressiva com formol')).toEqual(['progressiva', 'formol']);
  });

  it('não quebra com nome curto', () => {
    expect(palavrasDoServico('Corte')).toEqual(['corte']);
    expect(palavrasDoServico('')).toEqual([]);
  });
});

describe('preço e horário na fala', () => {
  it('acha o valor em vários formatos', () => {
    expect(precoFoiDito(['O valor fica a partir de R$ 430,00'])).toBe(true);
    expect(precoFoiDito(['Fica 90 reais'])).toBe(true);
    expect(precoFoiDito(['Qual o seu nome?'])).toBe(false);
  });

  it('acha o horário concreto', () => {
    expect(ofereceHorario(['Tenho amanhã, terça, às 13h, pode ser?'])).toBe(true);
    expect(ofereceHorario(['Tenho quinta 18/09 às 14:30'])).toBe(true);
    expect(ofereceHorario(['Qual o seu nome?'])).toBe(false);
  });

  it('servicoFoiDito olha só se o nome apareceu, não quem disse', () => {
    expect(servicoFoiDito(['as mechas ficam lindas'], 'Mechas morena iluminada')).toBe(true);
  });
});

describe('o que a CLIENTE fez com o serviço', () => {
  it('PEGA O CASO REAL: quem disse "coloração" foi o agente, não ela', () => {
    expect(escolhaDaCliente(NOITE_DE_14, 'Coloração')).toBe('NUNCA');
    expect(escolhaDaCliente(NOITE_DE_14, 'Mechas morena iluminada')).toBe('NUNCA');
  });

  it('PEGA O CASO REAL: "Não é coloração" é negativa, e vale para o resto da conversa', () => {
    expect(escolhaDaCliente(MANHA_DE_15, 'Coloração')).toBe('NEGOU');
  });

  it('separa contar a história de pedir', () => {
    // "Já fiz progressiva" contando química anterior não é pedido.
    expect(escolhaDaCliente(NOITE_DE_14, 'Progressiva com formol')).toBe('MENCIONOU');
    // "Eu gostaria de fazer uma progressiva" é.
    expect(escolhaDaCliente(MANHA_DE_15, 'Progressiva com formol')).toBe('ESCOLHEU');
  });

  it('um sim depois da pergunta certa vale como escolha', () => {
    const conversa = [
      cliente('Oi, quero marcar'),
      agente('Você quer fazer a morena iluminada?'),
      cliente('Isso mesmo'),
    ];
    expect(escolhaDaCliente(conversa, 'Mechas morena iluminada')).toBe('ESCOLHEU');
  });

  it('um sim para outra pergunta não vale como escolha', () => {
    const conversa = [
      cliente('Oi, quero marcar'),
      agente('Você já fez alguma química no cabelo?'),
      cliente('Sim'),
    ];
    expect(escolhaDaCliente(conversa, 'Mechas morena iluminada')).toBe('NUNCA');
  });

  it('sem serviço nenhum em foco, nunca houve escolha', () => {
    expect(escolhaDaCliente(MANHA_DE_15, null)).toBe('NUNCA');
  });
});

describe('os serviços que cabem no que ela pediu', () => {
  it('PEGA O CASO REAL: "uma progressiva" são cinco serviços, não um', () => {
    expect(servicosQueCabem(MANHA_DE_15, CATALOGO)).toEqual([
      'Progressiva 3D',
      'Progressiva 4D',
      'Progressiva com formol',
      'Progressiva japonesa',
      'Progressiva sem formol',
    ]);
  });

  it('o nome inteiro desempata', () => {
    const conversa = [cliente('queria fazer a progressiva com formol')];
    expect(servicosQueCabem(conversa, CATALOGO)).toEqual(['Progressiva com formol']);
  });

  it('"sem formol" descarta a "com formol", e não o contrário', () => {
    const conversa = [cliente('quero uma progressiva sem formol')];
    expect(servicosQueCabem(conversa, CATALOGO)).toEqual(['Progressiva sem formol']);
  });

  it('pedido sem nome de serviço não casa com nada', () => {
    const conversa = [cliente('Gostaria de marcar um procedimento')];
    expect(servicosQueCabem(conversa, CATALOGO)).toEqual([]);
  });
});

describe('afirmar o serviço em vez de perguntar', () => {
  it('PEGA O CASO REAL: "A coloração está R$ 160,00."', () => {
    expect(afirmaServico(['A coloração está R$ 160,00.'], 'Coloração')).toBe(true);
    expect(
      afirmaServico(['Certo, trocando então para progressiva com formol, fica R$ 200,00.'],
        'Progressiva com formol')
    ).toBe(true);
  });

  it('perguntar não é afirmar', () => {
    expect(afirmaServico(['Você quer fazer a coloração?'], 'Coloração')).toBe(false);
    expect(afirmaServico(['Tenho hoje às 13h para sua coloração, pode ser?'], 'Coloração')).toBe(
      false
    );
  });
});

describe('a trava inteira', () => {
  it('PEGA O CASO REAL de 14/09: horário de um serviço que ela nunca escolheu', () => {
    const r = travaDoProcedimento(
      ['Perfeito, Rayana!', 'Tenho amanhã, terça, às 13h, pode ser?'],
      NOITE_DE_14,
      'Mechas morena iluminada',
      CATALOGO
    );
    expect(r.falta).toBe('PROCEDIMENTO');
  });

  it('PEGA O CASO REAL de 15/09: "A coloração está R$ 160,00" depois de ela nunca ter pedido', () => {
    const ateAli = MANHA_DE_15.slice(0, 17);
    const r = travaDoProcedimento(['A coloração está R$ 160,00.'], ateAli, 'Coloração', CATALOGO);
    expect(r.falta).toBe('AFIRMOU');
  });

  it('PEGA O CASO REAL de 15/09: escolher sozinho uma das cinco progressivas', () => {
    const r = travaDoProcedimento(
      ['Certo, trocando então para progressiva com formol, o valor fica R$ 200,00.'],
      MANHA_DE_15,
      'Progressiva com formol',
      CATALOGO
    );
    expect(r.falta).toBe('IRMAOS');
    expect(r.opcoes).toHaveLength(5);
  });

  it('e também quando ele só oferece o horário da que escolheu por ela', () => {
    const r = travaDoProcedimento(
      ['Tenho hoje às 13h, pode ser?'],
      MANHA_DE_15,
      'Progressiva com formol',
      CATALOGO
    );
    expect(r.falta).toBe('IRMAOS');
  });

  it('deixa passar quando ela escolheu, o nome é único e o preço já foi dito', () => {
    const conversa = [
      cliente('Oi, queria fazer a morena iluminada'),
      agente('A morena iluminada fica R$ 420,00.'),
    ];
    const r = travaDoProcedimento(
      ['Tenho quinta às 14h, pode ser?'],
      conversa,
      'Mechas morena iluminada',
      CATALOGO
    );
    expect(r.falta).toBeNull();
  });

  it('cobra o preço quando ela escolheu e o valor nunca foi dito', () => {
    const conversa = [cliente('Oi, queria fazer a morena iluminada')];
    const r = travaDoProcedimento(
      ['Tenho quinta às 14h, pode ser?'],
      conversa,
      'Mechas morena iluminada',
      CATALOGO
    );
    expect(r.falta).toBe('PRECO');
  });

  it('não cobra nada quando a resposta é a pergunta certa', () => {
    const r = travaDoProcedimento(
      ['Então me conta, o que você quer fazer no cabelo?'],
      MANHA_DE_15.slice(0, 20),
      'Coloração',
      CATALOGO
    );
    expect(r.falta).toBeNull();
  });

  it('deixa perguntar qual das progressivas', () => {
    const r = travaDoProcedimento(
      ['São cinco progressivas aqui: 3D, 4D, japonesa, com formol e sem formol. Qual você quer?'],
      MANHA_DE_15,
      'Progressiva com formol',
      CATALOGO
    );
    expect(r.falta).toBeNull();
  });

  it('responder quanto custa um serviço que ela perguntou não é afirmar escolha', () => {
    const conversa = [cliente('quanto custa a coloração?')];
    const r = travaDoProcedimento(['A coloração está R$ 160,00.'], conversa, 'Coloração', CATALOGO);
    expect(r.falta).toBeNull();
  });
});

describe('as vozes da conversa', () => {
  it('separa quem falou o quê', () => {
    const volatil = {
      history: [
        { direction: 'INBOUND', text: 'oi' },
        { direction: 'OUTBOUND', text: 'olá!' },
        { direction: 'OUTBOUND', text: '   ' },
      ],
    };
    expect(falasDoAgente(volatil)).toEqual(['olá!']);
    expect(falasDaCliente(volatil)).toEqual(['oi']);
    expect(falasDoAgente(null)).toEqual([]);
  });
});

// 15/09, 15:44. A dona testando como cliente:
//   "Qual o valor da progressiva?"
//   "Eu estava querendo fazer um iluminado também, qual eu faço primeiro?"
// A trava ficou cega duas vezes: "iluminado" não casou com "iluminada", e o
// pedido dela estava repartido em duas mensagens.
const PEDIDO_EM_DUAS_MENSAGENS = [
  cliente('Boa tarde'),
  cliente('Qual o valor da progressiva?'),
  agente('Boa tarde! Tudo bem?'),
  agente('A progressiva fica R$ 200,00.'),
  agente('Qual o seu nome?'),
  cliente('Eduarda'),
  cliente('Eu estava querendo fazer um iluminado também, qual eu faço primeiro?'),
];

describe('o pedido dela não cabe numa mensagem só', () => {
  it('PEGA O CASO REAL: "iluminado" é a "Mechas morena iluminada" do catálogo', () => {
    expect(mencionaServico('quero um iluminado', 'Mechas morena iluminada')).toBe(true);
    expect(mencionaServico('quero umas luzes loiras', 'Mechas loiras — teste na semana')).toBe(true);
  });

  it('a raiz não faz tudo casar com tudo', () => {
    expect(mencionaServico('quero cortar a franja', 'Progressiva com formol')).toBe(false);
    expect(mencionaServico('vou fazer as unhas', 'Botox capilar')).toBe(false);
  });

  it('PEGA O CASO REAL: lê as duas mensagens e acha os dois serviços', () => {
    const cabem = servicosQueCabem(PEDIDO_EM_DUAS_MENSAGENS, CATALOGO);
    expect(cabem).toContain('Mechas morena iluminada');
    expect(cabem.filter((n) => n.startsWith('Progressiva'))).toHaveLength(5);
  });

  it('e aí oferecer horário de uma delas é prematuro', () => {
    const r = travaDoProcedimento(
      ['Tenho quinta às 14h para a progressiva, pode ser?'],
      PEDIDO_EM_DUAS_MENSAGENS,
      'Progressiva com formol',
      CATALOGO
    );
    expect(r.falta).toBe('IRMAOS');
  });

  it('sem verbo de pedido em nenhuma das falas, não há pedido', () => {
    const conversa = [cliente('Boa tarde'), cliente('Tudo bem?')];
    expect(servicosQueCabem(conversa, CATALOGO)).toEqual([]);
  });
});
