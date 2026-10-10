import { describe, expect, it } from 'vitest';

import { disseQueGravou } from '../../../supabase/functions/eddy-agent/disse-que-gravou';

// 10/10, PRODUÇÃO, William: "corte também entra no sinal de R$ 50 então. Já
// ajustei." -- nada gravado, e a trava não conhecia "ajustei".
describe('disse que gravou (10/10, William)', () => {
  it.each([
    'Beleza, corte também entra no sinal de R$ 50 então. Já ajustei.',
    'Pronto, ajustei aqui.',
    'Já coloquei o corte no sinal.',
    'Incluí a escova também.',
    'Já incluí a escova.',
    'Mudei o prazo para 48h.',
    'Troquei o valor.',
    'Tirei a manicure do sinal.',
    'Removi esse serviço.',
    'Defini o sinal em R$ 50.',
    'Configurei tudo.',
    'Ativei o sinal.',
    'Liguei o sinal pra dezembro.',
    'Desliguei o lembrete.',
    'Adicionei o selante.',
    'Acrescentei a escova na lista.',
    'Já está ajustado.',
    'Tudo ajustado!',
    'Já ficou configurado.',
    'Tá feito.',
    'Está feito, pode conferir.',
    'Já deixei registrado que essas regras valem só para dezembro.',
    'Anotei aqui.',
    'Cor gravada certinho',
    'Corrigi o preço.',
    'JÁ AJUSTEI',
  ])('afirma que fez: "%s"', (frase) => {
    expect(disseQueGravou([frase])).toBe(true);
  });

  it.each([
    'Quer que eu ative o sinal?',
    'Posso ajustar o prazo?',
    'Vou anotar isso.',
    'Quer incluir a escova?',
    'O sinal vale pra quem tem horário marcado em dezembro.',
    'Se a cliente mudou de ideia, ela avisa.',
    'O valor inclui a lavagem.',
    'Se ela desmarcar, o horário é liberado.',
    'Me diz quais procedimentos entram e o valor de cada um.',
    'Qual é o prazo pra pagar?',
    'Ela pode remarcar para janeiro.',
    'Ligar o sinal: ativar a cobrança de R$ 50 pra reservar horário em dezembro. Quer que eu ative?',
    'O ajuste fica com você.',
    'Defina o valor que eu gravo.',
    '',
  ])('não afirma: "%s"', (frase) => {
    expect(disseQueGravou([frase])).toBe(false);
  });

  it('várias bolhas: basta uma afirmar', () => {
    expect(disseQueGravou(['Entendi.', 'Já ajustei.', 'Mais alguma coisa?'])).toBe(true);
  });

  it('nulo e vazio não quebram', () => {
    expect(disseQueGravou([null, undefined, 3])).toBe(false);
    expect(disseQueGravou([])).toBe(false);
  });
});
