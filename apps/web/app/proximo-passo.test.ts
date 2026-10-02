import { describe, expect, it } from 'vitest';

import { comProximoPasso } from '../../../supabase/functions/eddy-agent/proximo-passo';

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
