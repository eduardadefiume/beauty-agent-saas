import { describe, expect, it } from 'vitest';

import { devolucaoDita } from '../../../supabase/functions/eddy-agent/devolucao-dita';

describe('a regra de devolução do sinal como o dono disse (02/10, William)', () => {
  it.each([
    ['sinal sim mas só pra quimica. e se desmarcar com menos de 24h não devolve', true, 24],
    ['com menos de 48 horas não devolve', true, 48],
    ['se cancelar com menos de 1 dia perde o sinal', true, 24],
    ['menos de dois dias não tem devolução', true, 48],
    ['devolve se avisar com 48h', true, 48],
    ['avisando 2 dias antes eu devolvo', true, 48],
    ['com mais de 24 horas eu devolvo o sinal', true, 24],
    ['devolvo se avisar uma semana antes', true, 168],
    ['reembolso só com 72hs de antecedência', true, 72],
    ['não devolve', false, null],
    ['o sinal não volta', false, null],
    ['não tem devolução não', false, null],
    ['desmarcou perdeu', false, null],
    ['nunca devolvo sinal', false, null],
    ['devolvo sempre', true, 0],
  ])('%s -> devolve=%s, %s h', (fala, devolve, ateHoras) => {
    expect(devolucaoDita(fala)).toEqual({ devolve, ateHoras });
  });

  it.each([
    'quero cobrar 50 de sinal',
    'o pix é 16 99999-0000',
    'sinal sim mas só pra quimica',
    'oi tudo bem',
  ])('não fala de devolução: %s -> null', (fala) => {
    expect(devolucaoDita(fala)).toBeNull();
  });
});

// 10/10, PRODUÇÃO, William de verdade: "o valor da entrada não será devolvido"
// virou "devolve com 48h". O leitor só via a negação colada ("não devolv"); com
// "não SERÁ devolvido" sobrou "devolvido" + "dois dias" (de outra regra, a da
// cobrança integral), e o código -- que prevalece sobre o modelo -- gravou o
// contrário do que o dono escreveu.
const REGRAS_DO_WILLIAM =
  'Regras para Agendamentos de Dezembro\n\t1.\tConfirmação de Horário: A reserva do horário só será garantida após o pagamento de uma taxa de R$ 50, que é uma entrada para o serviço desejado.\n\t2.\tPolítica de Remarcação e Cancelamento: Em caso de desmarcações ou trocas de horário, o valor da entrada não será devolvido, pois não haverá mais vagas disponíveis para ajustes em dezembro.\n\t3.\tOpção para Janeiro: Caso não possa comparecer no dia agendado, é possível reagendar para janeiro sem custo adicional, mas para dezembro não serão realizadas trocas de horário.\n\t4.\tPontualidade: Não serão tolerados atrasos superiores a 10 minutos para respeitar o horário das demais clientes.\n\t5.\tCancelamentos de Última Hora: Caso ocorra uma desmarcação a menos de dois dias da data marcada, será cobrado o valor total do serviço planejado.\n\nEssas políticas foram estabelecidas para garantir um atendimento organizado e satisfatório para todas as clientes durante o período de alta demanda.\n\nA taxa de entrada pode ser paga via Pix, usando a chave 16991319581, e será descontada do valor total do serviço.';

describe('negação com palavra no meio (10/10, William na produção)', () => {
  it('o texto real do William: não devolve', () => {
    expect(devolucaoDita(REGRAS_DO_WILLIAM)).toEqual({ devolve: false, ateHoras: null });
  });

  it('o turno real (regras + "são para dezembro") junto: não devolve', () => {
    expect(
      devolucaoDita(`${REGRAS_DO_WILLIAM} . Essas regras são para dezembro especificamente`)
    ).toEqual({ devolve: false, ateHoras: null });
  });

  it.each([
    'o valor da entrada não será devolvido',
    'o sinal não vai ser devolvido',
    'o sinal nao e devolvido',
    'a entrada não é devolvida em hipótese nenhuma',
    'o sinal não fica devolvido',
    'não haverá devolução do sinal',
    'não há devolução',
    'não tem reembolso',
    'sem reembolso',
    'não será reembolsado',
    'não fazemos devolução',
    'não devolvemos',
    'o valor não é reembolsável',
    'a taxa não será estornada',
    'NÃO SERÁ DEVOLVIDO',
    'nao sera devolvido',
  ])('"%s" -> não devolve', (fala) => {
    expect(devolucaoDita(fala)).toEqual({ devolve: false, ateHoras: null });
  });

  it.each([
    ['se desmarcar com menos de 24h o sinal não será devolvido', 24],
    ['com menos de 2 dias a entrada não vai ser devolvida', 48],
    ['desmarcando com menos de 48 horas não há devolução', 48],
  ])('"%s" -> devolve se avisar com %sh', (fala, h) => {
    expect(devolucaoDita(fala)).toEqual({ devolve: true, ateHoras: h });
  });

  it('cobrança integral não é regra de devolução', () => {
    expect(
      devolucaoDita(
        'Caso ocorra uma desmarcação a menos de dois dias da data marcada, será cobrado o valor total do serviço planejado.'
      )
    ).toBeNull();
  });

  it('"não devolve" e "devolve com 48h" na mesma fala, sem "menos de": não decide (fica com o modelo)', () => {
    expect(
      devolucaoDita('em dezembro não será devolvido. nos outros meses devolvo se avisar com 48h')
    ).toBeNull();
  });
});
