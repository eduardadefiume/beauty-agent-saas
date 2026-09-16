import { describe, expect, it } from 'vitest';

import {
  camposCorrompidos,
  semEscapes,
  temEscapeLiteral,
  semMarcacao,
  temMarcacao,
} from '../../../supabase/functions/whatsapp-agent/resposta-limpa';

// A marcacao e montada por pedacos de proposito: escrever a tag inteira num
// arquivo de codigo faz ferramenta de edicao tropecar, que e prima do mesmo
// problema que este modulo existe para pegar.
const FECHA_PARAMETRO = '<' + '/' + 'antml' + ':parameter>';
const ABRE_PARAMETRO = '<' + 'parameter name="contextSummary">';
const FECHA_INVOKE = '<' + '/' + 'invoke>';

describe('marcação de ferramenta vazando no texto', () => {
  it('reconhece a tag de fechamento que apareceu no painel da dona', () => {
    expect(temMarcacao(FECHA_PARAMETRO)).toBe(true);
  });

  it('reconhece a abertura de parâmetro', () => {
    expect(temMarcacao(ABRE_PARAMETRO)).toBe(true);
  });

  it('texto de gente passa limpo', () => {
    expect(temMarcacao('A cliente perguntou se pode parcelar. Aceita?')).toBe(false);
    expect(temMarcacao('Tenho sexta, 18/09, às 13h, pode ser?')).toBe(false);
    expect(temMarcacao('')).toBe(false);
    expect(temMarcacao(null)).toBe(false);
  });

  it('não confunde um "<" solto com marcação', () => {
    expect(temMarcacao('o valor é < 500 reais')).toBe(false);
  });
});

describe('campos corrompidos da decisão', () => {
  it('pega o caso real das 16:39, com a pergunta da dona quebrada', () => {
    const decisao = {
      messages: ['Tenho sexta, 18/09, às 13h, pode ser?'],
      ownerQuestion:
        FECHA_PARAMETRO + '\n' + ABRE_PARAMETRO + 'Cliente perguntou sobre parcelamento.',
      contextSummary: 'Cliente já confirmada para sexta.',
      reason: 'ofereci horário',
    };
    expect(camposCorrompidos(decisao)).toEqual(['ownerQuestion']);
  });

  it('messages sujo é o caso grave: é o único que sai para a cliente', () => {
    const decisao = {
      messages: ['Tudo certo!', 'Marcado' + FECHA_PARAMETRO],
      ownerQuestion: '',
      contextSummary: '',
      reason: '',
    };
    expect(camposCorrompidos(decisao)).toContain('messages');
  });

  it('decisão limpa não acusa nada', () => {
    const decisao = {
      messages: ['Oi, Duda! Tudo bem?', 'Tenho sexta às 13h, pode ser?'],
      ownerQuestion: 'A cliente perguntou se parcela. Aceita?',
      contextSummary: 'Quer mechas, já tem horário oferecido.',
      reason: 'ofereci horário e perguntei à dona sobre parcelamento',
    };
    expect(camposCorrompidos(decisao)).toEqual([]);
  });

  it('não quebra com decisão vazia', () => {
    expect(camposCorrompidos(null)).toEqual([]);
    expect(camposCorrompidos({})).toEqual([]);
  });
});

describe('tirar a marcação em vez de apagar o campo', () => {
  it('fica com o português que sobrou', () => {
    expect(semMarcacao('A cliente quer parcelar em 3x')).toBe('A cliente quer parcelar em 3x');
    expect(semMarcacao(ABRE_PARAMETRO + 'A cliente quer parcelar?')).toBe(
      'A cliente quer parcelar?'
    );
    expect(semMarcacao('Ela pergunta ' + FECHA_INVOKE + ' se dá para dividir')).toBe(
      'Ela pergunta se dá para dividir'
    );
  });

  it('devolve vazio quando não sobra frase nenhuma', () => {
    expect(semMarcacao(FECHA_PARAMETRO)).toBe('');
    expect(semMarcacao('   ')).toBe('');
    expect(semMarcacao(null)).toBe('');
    expect(semMarcacao(42)).toBe('');
  });
});

// 16/09, 16:24. A cliente leu, na tela do WhatsApp dela:
//   "Luzes \\u00e9 uma fam\\u00edlia tamb\\u00e9m, Eduarda"
// No banco: 194 bytes para 194 caracteres. Português com acento sempre tem
// mais bytes que caracteres; quando batem, não sobrou acento nenhum.
describe('o escape do JSON escrito como letra', () => {
  it('PEGA O CASO REAL: devolve os acentos que se perderam', () => {
    expect(semEscapes('Luzes \\u00e9 uma fam\\u00edlia tamb\\u00e9m, e ilumina s\\u00f3 no contorno.')).toBe(
      'Luzes é uma família também, e ilumina só no contorno.'
    );
  });

  it('e reconhece que o texto está sujo', () => {
    expect(temEscapeLiteral('Luzes \\u00e9 uma fam\\u00edlia')).toBe(true);
    expect(temEscapeLiteral('Luzes é uma família')).toBe(false);
  });

  it('texto limpo passa intacto', () => {
    const limpo = 'A progressiva com formol fica R$ 200,00, Eduarda. Qual você prefere?';
    expect(semEscapes(limpo)).toBe(limpo);
  });

  it('barra invertida que não é escape fica onde está', () => {
    expect(semEscapes('um caminho C:\\temp que fica')).toBe('um caminho C:\\temp que fica');
    expect(semEscapes('50\\50 entre as duas')).toBe('50\\50 entre as duas');
  });

  it('quebra de linha escrita como letra vira quebra de linha', () => {
    expect(semEscapes('primeira\\nsegunda')).toBe('primeira\nsegunda');
  });
});
