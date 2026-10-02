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
});
