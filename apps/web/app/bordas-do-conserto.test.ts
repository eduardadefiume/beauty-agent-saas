// AS BORDAS DAS LINHAS QUE O CONSERTO DO BUILD MEXEU (09/10).
//
// 09/10: a produção estava fora do ar. `next build` roda o TypeScript do
// apps/web, e o tsconfig do apps/web puxa estes arquivos do Deno pelos
// imports dos testes. Com `noUncheckedIndexedAccess`, todo `m[1]` de regex,
// todo `array[0]` e todo `MAPA[chave]` é `| undefined` -- 26 erros em 9
// arquivos, e o build morria no primeiro ("Object is possibly 'undefined'",
// cor-confirmada.ts:42).
//
// O conserto tirou os acessos sem guarda. Estes testes são a matriz das
// bordas de cada linha mexida: entrada vazia, lista vazia, chave que não
// existe, número que vira zero, meia-noite -- justo os casos em que o
// `undefined` apareceria de verdade. Nenhum deles muda o comportamento
// combinado; servem para o conserto não ter mudado nada à revelia e para a
// borda não voltar.

import { describe, expect, it } from 'vitest';

import type { Fala } from '../../../supabase/functions/whatsapp-agent/antes-do-horario';
import { servicosQueCabem } from '../../../supabase/functions/whatsapp-agent/antes-do-horario';
import { corConfirmada } from '../../../supabase/functions/eddy-agent/cor-confirmada';
import { devolucaoDita } from '../../../supabase/functions/eddy-agent/devolucao-dita';
import { padraoDaCor } from '../../../supabase/functions/eddy-agent/proximo-passo';
import { valorDaQuimicaDito } from '../../../supabase/functions/eddy-agent/sinal-quimica-dito';
import { horarioApareceuNaConversa } from '../../../supabase/functions/whatsapp-agent/horario-combinado';
import { nomeDito } from '../../../supabase/functions/whatsapp-agent/nome-dito';
import { bolhasDaResposta } from '../../../supabase/functions/whatsapp-agent/formato-da-resposta';
import { pediuOutroServico } from '../../../supabase/functions/whatsapp-agent/servico-pedido';

const cliente = (text: string): Fala => ({ direction: 'INBOUND', text });

const c = (unidade: string, valor: number, falaDoDono: string, ultimaDoEddy = '') =>
  corConfirmada({ unidade, valor, falaDoDono, ultimaDoEddy });

describe('cor-confirmada: o número que ele disse (borda de m[1])', () => {
  it('fala vazia não confirma nada, em nenhuma unidade', () => {
    for (const u of ['NIVEIS', 'MINUTOS', 'REAIS', 'SIM_NAO']) {
      expect(c(u, 0, '')).toBe(false);
      expect(c(u, 1, '')).toBe(false);
      expect(c(u, 30, '   ')).toBe(false);
    }
  });
  it('fala só com pontuação não confirma', () => {
    expect(c('REAIS', 50, '...')).toBe(false);
    expect(c('MINUTOS', 30, '???')).toBe(false);
  });
  it('decimal com ponto e com vírgula valem o mesmo', () => {
    expect(c('REAIS', 49.9, 'R$ 49,90')).toBe(true);
    expect(c('REAIS', 49.9, 'R$ 49.90')).toBe(true);
  });
  it('dois números na mesma frase: os dois contam', () => {
    expect(c('NIVEIS', 2, 'entre 2 e 3 niveis')).toBe(true);
    expect(c('NIVEIS', 3, 'entre 2 e 3 niveis')).toBe(true);
    expect(c('NIVEIS', 4, 'entre 2 e 3 niveis')).toBe(false);
  });
  it('número colado na palavra conta', () => {
    expect(c('REAIS', 50, 'cobro 50reais')).toBe(true);
  });
  it('tempo em extenso: meia hora, uma hora, uma hora e meia, duas horas, 2h', () => {
    expect(c('MINUTOS', 30, 'meia hora')).toBe(true);
    expect(c('MINUTOS', 60, 'uma hora')).toBe(true);
    expect(c('MINUTOS', 90, 'uma hora e meia')).toBe(true);
    expect(c('MINUTOS', 120, 'duas horas')).toBe(true);
    expect(c('MINUTOS', 120, '2h')).toBe(true);
  });
});

describe('devolucao-dita: a janela em horas (borda de m[1]/m[2])', () => {
  it('"0h" não vira janela de zero hora -- cai no "não devolve" seco', () => {
    expect(devolucaoDita('se desmarcar com menos de 0h nao devolve')).toEqual({
      devolve: false,
      ateHoras: null,
    });
  });
  it('unidade em dias e em semanas vira hora', () => {
    expect(devolucaoDita('com menos de um dia perde o sinal')).toEqual({
      devolve: true,
      ateHoras: 24,
    });
    expect(devolucaoDita('devolvo se avisar com duas semanas')).toEqual({
      devolve: true,
      ateHoras: 336,
    });
  });
  it('número em extenso que não está na tabela não inventa janela', () => {
    expect(devolucaoDita('com menos de cem horas nao devolve')).toEqual({
      devolve: false,
      ateHoras: null,
    });
  });
  it('fala vazia e fala sem assunto de devolução: null', () => {
    expect(devolucaoDita('')).toBeNull();
    expect(devolucaoDita('quero cadastrar a progressiva')).toBeNull();
  });
});

describe('nome-dito: a apresentação dela (borda de m[1] e de split[0])', () => {
  it('lista vazia e falas vazias: null, sem quebrar', () => {
    expect(nomeDito([])).toBeNull();
    expect(nomeDito([''])).toBeNull();
    expect(nomeDito(['', '  ', ''])).toBeNull();
  });
  it('pega a última apresentação, não a primeira', () => {
    expect(nomeDito(['sou a Bia', 'quero corte', 'na verdade me chamo Beatriz'])).toBe('Beatriz');
  });
  it('primeira palavra que não é nome descarta a fala inteira', () => {
    expect(nomeDito(['sou a mesma de sempre'])).toBeNull();
    expect(nomeDito(['sou a dona do salao'])).toBeNull();
  });
});

describe('horario-combinado: a hora do agendamento (borda de split)', () => {
  // Meia-noite em São Paulo (UTC-3) = 03:00 UTC do mesmo dia.
  const MEIA_NOITE = Date.UTC(2026, 9, 3, 3, 0);
  const NOVE_H = Date.UTC(2026, 9, 3, 12, 0);

  it('meia-noite não casa com uma conversa que falou de 9h', () => {
    expect(horarioApareceuNaConversa([cliente('pode ser 9 horas?')], MEIA_NOITE)).toBe(false);
  });
  it('conversa vazia nunca viu horário nenhum', () => {
    expect(horarioApareceuNaConversa([], NOVE_H)).toBe(false);
    expect(horarioApareceuNaConversa([], MEIA_NOITE)).toBe(false);
  });
});

describe('servico-pedido: o primeiro serviço nomeado (borda de ditos[0])', () => {
  it('catálogo vazio e fala vazia: null', () => {
    expect(pediuOutroServico([], 'Teste de mecha', [])).toBeNull();
    expect(pediuOutroServico([''], 'Teste de mecha', ['Luzes'])).toBeNull();
  });
  it('sem serviço para marcar: null', () => {
    expect(pediuOutroServico(['quero as luzes'], null, ['Luzes'])).toBeNull();
    expect(pediuOutroServico(['quero as luzes'], undefined, ['Luzes'])).toBeNull();
  });
  it('ela nomeou outro: devolve o outro', () => {
    expect(
      pediuOutroServico(['pode sim, as luzes dia 3 as 9h'], 'Teste de mecha', [
        'Luzes',
        'Teste de mecha',
      ])
    ).toBe('Luzes');
  });
  it('ela nomeou o que vai ser marcado: null', () => {
    expect(
      pediuOutroServico(['pode o teste de mecha'], 'Teste de mecha', ['Luzes', 'Teste de mecha'])
    ).toBeNull();
  });
});

describe('proximo-passo: o padrão da cor (borda de ROTULO[chave])', () => {
  it('lista vazia: texto vazio', () => {
    expect(padraoDaCor([])).toBe('');
  });
  it('sugestão que não é número fica fora', () => {
    expect(padraoDaCor([{ chave: 'MINUTOS_MATIZACAO', pergunta: 'Quantos min?' }])).toBe('');
  });
  it('chave desconhecida ou ausente cai na pergunta, não quebra', () => {
    expect(
      padraoDaCor([{ chave: 'CHAVE_QUE_NAO_EXISTE', pergunta: 'Quanto custa?', sugestao: 20 }])
    ).toContain('Quanto custa: 20');
    expect(padraoDaCor([{ pergunta: 'Quanto custa?', sugestao: 20 }])).toContain(
      'Quanto custa: 20'
    );
  });
  it('chave conhecida usa o rótulo', () => {
    expect(padraoDaCor([{ chave: 'MINUTOS_MATIZACAO', sugestao: 20 }])).toContain(
      'matização leva 20 min'
    );
  });
});

describe('sinal-quimica-dito: o valor do sinal (borda de m[1] e de POR_EXTENSO[chave])', () => {
  it('fala vazia: null', () => {
    expect(valorDaQuimicaDito('')).toBeNull();
    expect(valorDaQuimicaDito('   ')).toBeNull();
  });
  it('zero não é valor de sinal', () => {
    expect(valorDaQuimicaDito('sinal de 0 pra quimica')).toBeNull();
  });
  it('extenso composto vale', () => {
    expect(valorDaQuimicaDito('cento e cinquenta reais pra quimica')).toBe(150);
  });
  it('extenso fora da tabela não inventa valor', () => {
    expect(valorDaQuimicaDito('mil reais pra quimica')).toBeNull();
  });
  it('número que não é dinheiro não vira sinal', () => {
    expect(valorDaQuimicaDito('a quimica demora 24h')).toBeNull();
  });
});

describe('antes-do-horario: polaridade feminino/masculino (borda do par)', () => {
  const catalogo = ['Corte feminino', 'Corte masculino'];
  it('"corte feminino" tira o masculino, e vice-versa', () => {
    expect(servicosQueCabem([cliente('quanto ta o corte feminino?')], catalogo)).toEqual([
      'Corte feminino',
    ]);
    expect(servicosQueCabem([cliente('quanto ta o corte masculino?')], catalogo)).toEqual([
      'Corte masculino',
    ]);
  });
  it('pergunta com os dois lados não descarta nenhum', () => {
    expect(
      servicosQueCabem([cliente('quanto ta o corte feminino e o masculino?')], catalogo)
    ).toEqual(['Corte feminino', 'Corte masculino']);
    expect(
      servicosQueCabem([cliente('quanto custa o corte feminino ou o masculino?')], catalogo)
    ).toEqual(['Corte feminino', 'Corte masculino']);
  });
});

describe('formato-da-resposta: a última bolha (borda de bolhas[length - 1])', () => {
  it('resposta vazia: nenhuma bolha', () => {
    expect(bolhasDaResposta({})).toEqual([]);
    expect(bolhasDaResposta({ bolha1: '', bolha2: '   ', bolha3: '', pergunta: '' })).toEqual([]);
  });
  it('só pergunta, sem bolha: a pergunta é a bolha', () => {
    expect(bolhasDaResposta({ bolha1: '', pergunta: 'Qual o seu nome?' })).toEqual([
      'Qual o seu nome?',
    ]);
  });
  it('pergunta entra no fim da última bolha com texto', () => {
    expect(
      bolhasDaResposta({ bolha1: 'Oi!', bolha3: 'Tenho sábado.', pergunta: 'Pode ser?' })
    ).toEqual(['Oi!', 'Tenho sábado.\n\nPode ser?']);
  });
  it('pergunta já escrita dentro da bolha não dobra', () => {
    expect(bolhasDaResposta({ bolha1: 'Tenho sábado. Pode ser?', pergunta: 'Pode ser?' })).toEqual([
      'Tenho sábado. Pode ser?',
    ]);
  });
  it('formato antigo (messages) continua valendo, inclusive vazio e sujo', () => {
    expect(bolhasDaResposta({ messages: ['a', '', '  b  '] })).toEqual(['a', 'b']);
    expect(bolhasDaResposta({ messages: [] })).toEqual([]);
    expect(bolhasDaResposta({ messages: 'nao e lista' })).toEqual([]);
  });
});
