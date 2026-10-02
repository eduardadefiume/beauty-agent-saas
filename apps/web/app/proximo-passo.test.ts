import { describe, expect, it } from 'vitest';

import {
  comProximoPasso,
  padraoDaCor,
  semRefrao,
} from '../../../supabase/functions/eddy-agent/proximo-passo';

const COR =
  'Agora, cor e mechas: prefere me mandar fotos de trabalhos seus ou um áudio explicando como você trabalha com cor?';

// 02/10, DEV, William-robô: "pode deixar o padrão" -> "Fechado, fica no modelo
// padrão." e mais nada. A pergunta da cor tinha saído junto da outra e o filtro
// de "não repita" a engoliu: conversa morta, dono sem saber o próximo passo.
describe('a resposta do cadastro nunca morre sem próximo passo (02/10)', () => {
  it('caso real do William', () => {
    expect(
      comProximoPasso(['Fechado, fica no modelo padrão de explicação do teste de mecha.'], {
        proxima: COR,
        leva: 'pode deixar o padrão',
        bloqueado: false,
      })
    ).toEqual(['Fechado, fica no modelo padrão de explicação do teste de mecha.', COR]);
  });

  it('"Feito. Mais alguma mudança?" -> "não": volta ao roteiro', () => {
    expect(comProximoPasso(['Beleza!'], { proxima: COR, leva: 'não', bloqueado: false })).toEqual([
      'Beleza!',
      COR,
    ]);
  });

  it('cumprimento não conta como pergunta', () => {
    expect(
      comProximoPasso(['Oi William, tudo bem?'], { proxima: COR, leva: 'oi', bloqueado: false })
    ).toEqual(['Oi William, tudo bem?', COR]);
  });

  it.each([
    [['Anotei. Mais alguma mudança?'], 'muda o corte pra 90', false, COR],
    [['Anotei.'], 'muda o corte pra 90', true, COR], // adiado / sinal em andamento
    [['Fechado!'], 'por hoje é só, amanhã continuo', false, COR],
    [['Fechado!'], 'vou atender uma cliente, falo depois', false, COR],
    [['Fechado!'], 'tenho que ir agora', false, COR],
    [['Fechado!'], 'ok', false, ''], // roteiro vazio
    [[], 'ok', false, COR], // sem resposta nenhuma: não inventa só a pergunta
  ])('não mexe: %j / %s', (msgs, leva, bloqueado, proxima) => {
    expect(comProximoPasso(msgs, { proxima, leva, bloqueado })).toEqual(msgs);
  });

  it('não repete pergunta já feita; usa a próxima sub-pergunta da etapa (02/10, deslize 9)', () => {
    const sub = 'Até quantos níveis a coloração daqui clareia sem precisar descolorir?';
    expect(
      comProximoPasso(['Anotei: Platinado fica R$100 a mais e 2h a mais.'], {
        proxima: COR,
        leva: 'o platinado demora 2h a mais tbm',
        bloqueado: false,
        jaFeitas: ['Então sobre cor e mechas: blá', COR],
        alternativas: [sub],
      })
    ).toEqual(['Anotei: Platinado fica R$100 a mais e 2h a mais.', sub]);
  });

  it('pergunta e sub-perguntas todas já feitas: não acrescenta nada', () => {
    const sub = 'Até quantos níveis clareia?';
    expect(
      comProximoPasso(['Anotei.'], {
        proxima: COR,
        leva: 'ok',
        bloqueado: false,
        jaFeitas: [COR, sub],
        alternativas: [sub],
      })
    ).toEqual(['Anotei.']);
  });

  it.each([
    'foto depois te mando',
    'te mando depois as fotos',
    'mando mais tarde',
    'depois eu mando',
    'amanhã te envio',
  ])('adiou: %s', (leva) => {
    expect(comProximoPasso(['Beleza!'], { proxima: COR, leva, bloqueado: false })).toEqual([
      'Beleza!',
    ]);
  });
});

describe('o filtro de refrão nunca apaga a resposta inteira (02/10, deslize 10)', () => {
  const fotos = (t: string) => /fotos?/i.test(t);
  it('as duas bolhas falam de fotos: fica tudo', () => {
    const msgs = [
      'Verdade, você já me explicou por áudio! Fico esperando as fotos.',
      'Enquanto as fotos não chegam: tem alguma regra sua que a atendente precisa saber?',
    ];
    expect(semRefrao(msgs, fotos)).toEqual(msgs);
  });
  it('só uma é refrão: ela sai', () => {
    expect(semRefrao(['Fico esperando as fotos.', 'Tem alguma regra sua?'], fotos)).toEqual([
      'Tem alguma regra sua?',
    ]);
  });
  it('uma bolha só: não mexe', () => {
    expect(semRefrao(['Fico esperando as fotos.'], fotos)).toEqual(['Fico esperando as fotos.']);
  });
  it('nenhuma é refrão: não mexe', () => {
    expect(semRefrao(['Anotei.', 'Tem alguma regra?'], fotos)).toEqual([
      'Anotei.',
      'Tem alguma regra?',
    ]);
  });
});

describe('o padrão da cor numa mensagem só (02/10)', () => {
  const todas = [
    { chave: 'CLAREIA_SEM_DESCOLORIR', unidade: 'NIVEIS', sugestao: 2 },
    { chave: 'TESTE_A_PARTIR_DE', unidade: 'NIVEIS', sugestao: 3 },
    { chave: 'MINUTOS_POR_NIVEL', unidade: 'MINUTOS', sugestao: 30 },
    { chave: 'REAIS_POR_NIVEL', unidade: 'REAIS', sugestao: 0 },
    { chave: 'MINUTOS_PRE_PIGMENTACAO', unidade: 'MINUTOS', sugestao: 40 },
    { chave: 'REAIS_PRE_PIGMENTACAO', unidade: 'REAIS', sugestao: 0 },
    { chave: 'MINUTOS_MATIZACAO', unidade: 'MINUTOS', sugestao: 30 },
    { chave: 'REAIS_MATIZACAO', unidade: 'REAIS', sugestao: 0 },
    { chave: 'QUIMICA_EXIGE_TESTE', unidade: 'SIM_NAO', sugestao: 1 },
  ];
  it('as 9, com uma pergunta só no fim', () => {
    const t = padraoDaCor(todas);
    expect(t).toContain('clareia até 2 níveis');
    expect(t).toContain('matização inclusa');
    expect(t).toContain('sempre faz teste');
    expect(t.match(/\?/g)?.length).toBe(1);
  });
  it('só as que faltam', () => {
    const t = padraoDaCor(todas.slice(6));
    expect(t).not.toContain('clareia');
    expect(t).toContain('matização leva 30 min');
  });
  it('valor cobrado aparece em reais', () => {
    expect(padraoDaCor([{ chave: 'REAIS_MATIZACAO', unidade: 'REAIS', sugestao: 50 }])).toContain(
      'matização R$ 50'
    );
  });
  it('chave nova desconhecida usa a pergunta', () => {
    expect(
      padraoDaCor([{ chave: 'NOVA', pergunta: 'Quantos minutos de pausa?', sugestao: 15 }])
    ).toContain('Quantos minutos de pausa: 15');
  });
  it('nada pendente: vazio', () => {
    expect(padraoDaCor([])).toBe('');
  });
});
