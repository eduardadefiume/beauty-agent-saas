import { describe, expect, it } from 'vitest';

import {
  camposCorrompidos,
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
