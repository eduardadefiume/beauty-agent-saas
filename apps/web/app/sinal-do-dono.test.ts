import { describe, expect, it } from 'vitest';

import { respostaAoSinal } from '../../../supabase/functions/eddy-agent/sinal-do-dono';

const AVISO =
  '💰 *Comprovante de sinal* (#S9424)\nMarina mandou o comprovante do sinal de *R$ 100* — Luzes, terça 01/12 às 9h.\n\nCaiu na sua conta? Me responde *sim* ou *não*.';
const COBRANCA =
  '⏰ O prazo do sinal da Marina venceu agora, mas ela mandou o comprovante antes (#S9424).';

describe('o dono responde o aviso do sinal (01/10)', () => {
  it.each([
    ['sim', true],
    ['Sim!', true],
    ['siiim', true],
    ['caiu', true],
    ['caiu sim', true],
    ['já caiu', true],
    ['Pode confirmar', true],
    ['recebi', true],
    ['👍', true],
    ['ok', true],
    ['não', false],
    ['nao caiu', false],
    ['Não caiu ainda', false],
    ['ainda não', false],
    ['nada', false],
  ])('%s -> pagou=%s', (fala, pagou) => {
    expect(respostaAoSinal(fala, AVISO, 1)).toEqual({ pagou, referencia: '' });
  });

  it('com código', () => {
    expect(respostaAoSinal('sim #S9424', AVISO, 2)).toEqual({ pagou: true, referencia: 'S9424' });
    expect(respostaAoSinal('S9424 não caiu', AVISO, 2)).toEqual({
      pagou: false,
      referencia: 'S9424',
    });
  });

  it('depois da cobrança do prazo também vale', () => {
    expect(respostaAoSinal('sim', COBRANCA, 1)).toEqual({ pagou: true, referencia: '' });
  });

  it.each([
    ['sim', 'Quer que eu publique agora?', 1, 'a última fala do Eddy não era o aviso'],
    ['sim', AVISO, 0, 'nada esperando'],
    ['caiu?', AVISO, 1, 'pergunta'],
    ['sim, mas a da Bia ainda não', AVISO, 2, 'dois assuntos'],
    ['muda o preço do corte pra 90', AVISO, 1, 'outro assunto'],
    ['a Marina pagou sim, e aproveita e me diz quantas clientes tenho amanhã', AVISO, 1, 'longo'],
  ])('%s -> modelo (%s)', (fala, ultima, pendentes) => {
    expect(respostaAoSinal(fala, ultima as string, pendentes as number)).toBeNull();
  });
});
