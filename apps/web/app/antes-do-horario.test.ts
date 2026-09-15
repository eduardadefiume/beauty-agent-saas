// A trava que impede oferecer horário de um procedimento que a cliente não
// escolheu. O caso real de 14/09 está inteiro no primeiro teste.

import { describe, expect, it } from 'vitest';

import {
  horarioSemProcedimentoOuPreco,
  ofereceHorario,
  palavrasDoServico,
  precoFoiDito,
  servicoFoiDito,
} from '../../../supabase/functions/whatsapp-agent/antes-do-horario';

// O que o agente falou com a Rayana, na ordem. Oito mensagens e nenhuma
// dizendo o que ele ia marcar.
const CONVERSA_DA_RAYANA = [
  'Oi, boa noite! Tudo bem?',
  'Qual o seu nome?',
  'Prazer, Rayana!',
  'Me manda uma foto do seu cabelo hoje, como ele está?',
  'Você já fez alguma química no cabelo, Rayana?',
  'Além da pintura, você já fez alguma química no cabelo, tipo progressiva ou alisamento?',
  'Faz quanto tempo que você fez essa química, Rayana?',
  'Você sabe se essa química tinha formol?',
];

describe('as palavras que identificam um serviço', () => {
  it('descarta conectivo e palavra genérica', () => {
    expect(palavrasDoServico('Mechas morena iluminada')).toEqual([
      'mechas',
      'morena',
      'iluminada',
    ]);
    expect(palavrasDoServico('Mechas loiras — teste no mesmo dia')).toEqual(['mechas', 'loiras']);
  });

  it('não quebra com nome curto', () => {
    expect(palavrasDoServico('Corte')).toEqual(['corte']);
    expect(palavrasDoServico('')).toEqual([]);
  });
});

describe('o serviço foi dito na conversa', () => {
  it('reconhece o nome mesmo escrito de outro jeito', () => {
    expect(servicoFoiDito(['Morena iluminada fica a partir de R$ 430'], 'Mechas morena iluminada'))
      .toBe(true);
    expect(servicoFoiDito(['as mechas ficam lindas'], 'Mechas morena iluminada')).toBe(true);
  });

  it('não confunde conversa sobre química com o nome do serviço', () => {
    expect(servicoFoiDito(CONVERSA_DA_RAYANA, 'Mechas morena iluminada')).toBe(false);
  });
});

describe('preço e horário na fala', () => {
  it('acha o valor em vários formatos', () => {
    expect(precoFoiDito(['O valor fica a partir de R$ 430,00'])).toBe(true);
    expect(precoFoiDito(['Fica 90 reais'])).toBe(true);
    expect(precoFoiDito(CONVERSA_DA_RAYANA)).toBe(false);
  });

  it('acha o horário concreto', () => {
    expect(ofereceHorario(['Tenho amanhã, terça, às 13h, pode ser?'])).toBe(true);
    expect(ofereceHorario(['Tenho quinta 18/09 às 14:30'])).toBe(true);
    expect(ofereceHorario(['Qual o seu nome?'])).toBe(false);
  });
});

describe('horário sem procedimento ou sem preço', () => {
  it('PEGA O CASO REAL: horário oferecido sem nunca dizer o procedimento', () => {
    const resultado = horarioSemProcedimentoOuPreco(
      ['Perfeito, Rayana!', 'Tenho amanhã, terça, às 13h, pode ser?'],
      CONVERSA_DA_RAYANA,
      'Mechas morena iluminada'
    );
    expect(resultado.falta).toBe('PROCEDIMENTO');
  });

  it('cobra o preço quando o procedimento já foi dito e o valor não', () => {
    const resultado = horarioSemProcedimentoOuPreco(
      ['Tenho terça às 13h, pode ser?'],
      [...CONVERSA_DA_RAYANA, 'Então seria a morena iluminada, certo?'],
      'Mechas morena iluminada'
    );
    expect(resultado.falta).toBe('PRECO');
  });

  it('deixa passar quando os dois já foram ditos', () => {
    const resultado = horarioSemProcedimentoOuPreco(
      [
        'Morena iluminada fica a partir de R$ 430,00, incluso hidratação e reconstrução.',
        'Tenho terça às 13h, pode ser?',
      ],
      CONVERSA_DA_RAYANA,
      'Mechas morena iluminada'
    );
    expect(resultado.falta).toBeNull();
  });

  it('aceita o que foi dito em mensagens anteriores da conversa', () => {
    const resultado = horarioSemProcedimentoOuPreco(
      ['Tenho terça às 13h, pode ser?'],
      ['A morena iluminada fica a partir de R$ 430,00.'],
      'Mechas morena iluminada'
    );
    expect(resultado.falta).toBeNull();
  });

  it('não cobra nada quando a resposta não oferece horário', () => {
    const resultado = horarioSemProcedimentoOuPreco(
      ['Você já fez alguma química no cabelo?'],
      CONVERSA_DA_RAYANA,
      'Mechas morena iluminada'
    );
    expect(resultado.falta).toBeNull();
  });

  it('sem serviço nenhum definido, horário é sempre prematuro', () => {
    const resultado = horarioSemProcedimentoOuPreco(
      ['Tenho terça às 13h, pode ser?'],
      CONVERSA_DA_RAYANA,
      null
    );
    expect(resultado.falta).toBe('PROCEDIMENTO');
  });
});
