// Errar é um problema, continuar no erro é pior.
//
// A conversa de 16/09, no número de verdade, com todas as travas anteriores já
// no ar. Ela perguntou "esse valor é com formol ou sem formol?" e ele respondeu
// "Com formol, Eduarda." mais a MESMA frase da foto que já tinha mandado 51
// minutos antes, caractere por caractere.

import { describe, expect, it } from 'vitest';

import type { Fala } from '../../../supabase/functions/whatsapp-agent/antes-do-horario';
import {
  avisoDeVolta,
  frases,
  frasesRepetidas,
  mesmaFrase,
  voltasDaCliente,
} from '../../../supabase/functions/whatsapp-agent/nao-insista';

const agente = (text: string): Fala => ({ direction: 'OUTBOUND', text });
const cliente = (text: string): Fala => ({ direction: 'INBOUND', text });

const A_FOTO = 'Ainda estou esperando aquela foto do seu cabelo hoje, pode me mandar?';

// A conversa real, na ordem, até a mensagem dela das 10:56.
const DIA_16 = [
  cliente('Boa tarde'),
  cliente('Qual o valor da progressiva?'),
  agente('Boa tarde! Tudo bem?'),
  agente('A progressiva fica R$ 200,00.'),
  agente('Qual o seu nome?'),
  cliente('Tudo bem e com você?'),
  cliente('Eduarda'),
  cliente('Eu estava querendo fazer um iluminado também, qual eu faço primeiro?'),
  agente('Progressiva primeiro, Eduarda, não indico fazer as duas químicas no mesmo período.'),
  agente('Manda uma foto do seu cabelo hoje, como ele está?'),
  cliente('Bom dia'),
  cliente('Qual o valor da progressiva?'),
  agente('Bom dia, Eduarda! A progressiva fica R$ 200,00.'),
  agente(A_FOTO),
  cliente('Esse valor é com formol ou sem formol?'),
];

const ditoPeloAgente = (historico: Fala[]) =>
  historico.filter((f) => f.direction === 'OUTBOUND').map((f) => String(f.text ?? ''));

describe('a mesma frase de novo', () => {
  it('PEGA O CASO REAL: a pergunta da foto reenviada palavra por palavra', () => {
    expect(frasesRepetidas([A_FOTO], ditoPeloAgente(DIA_16))).toEqual([A_FOTO]);
  });

  it('e pega o preço repetido das 10:07, que também já tinha saído às 15:39', () => {
    const ate1005 = DIA_16.slice(0, 12);
    const repetidas = frasesRepetidas(
      ['Bom dia, Eduarda! A progressiva fica R$ 200,00.'],
      ditoPeloAgente(ate1005)
    );
    expect(repetidas).toHaveLength(1);
  });

  it('frase nova passa', () => {
    const nova = ['Me expressei mal: são cinco progressivas aqui, e todas ficam R$ 200,00.'];
    expect(frasesRepetidas(nova, ditoPeloAgente(DIA_16))).toEqual([]);
  });

  it('a mesma pergunta reescrita também conta', () => {
    const antes = ['Manda uma foto do seu cabelo hoje, como ele está?'];
    expect(frasesRepetidas([A_FOTO], antes)).toHaveLength(1);
  });

  it('frase curta não conta: cumprimento se repete e tudo bem', () => {
    expect(frasesRepetidas(['Bom dia!'], ['Bom dia!'])).toEqual([]);
  });

  it('com formol e sem formol NÃO são a mesma frase, por mais parecidas', () => {
    const [comFormol] = frases('A progressiva com formol fica R$ 200,00 e leva 145 minutos.');
    const [semFormol] = frases('A progressiva sem formol fica R$ 200,00 e leva 145 minutos.');
    expect(mesmaFrase(comFormol!, semFormol!)).toBe(false);
  });

  it('nem dois horários diferentes', () => {
    const [quinta] = frases('Tenho quinta às 14:00 para você, pode ser bom?');
    const [sexta] = frases('Tenho sexta às 16:00 para você, pode ser bom?');
    expect(mesmaFrase(quinta!, sexta!)).toBe(false);
  });
});

describe('a cliente voltou num ponto já tratado', () => {
  it('PEGA O CASO REAL: "com formol ou sem formol?" é ela pedindo a diferença', () => {
    const voltas = voltasDaCliente(DIA_16);
    expect(voltas.map((v) => v.tipo)).toEqual(['PEDIU_ENTRE_DOIS']);
  });

  it('e o aviso diz, com todas as letras, que escolher por ela é o erro', () => {
    const aviso = avisoDeVolta(voltasDaCliente(DIA_16));
    expect(aviso).toContain('ainda NÃO escolheu');
    expect(aviso).toContain('escolhendo uma delas por ela é o erro');
  });

  it('ela repetir a pergunta do preço é a resposta anterior não ter servido', () => {
    const ate1005 = DIA_16.slice(0, 12);
    const voltas = voltasDaCliente(ate1005);
    expect(voltas).toHaveLength(1);
    expect(voltas[0]!.tipo).toBe('REPETIU_PERGUNTA');
    expect(avisoDeVolta(voltas)).toContain('PERGUNTOU DE NOVO');
  });

  it('"não é coloração" é ela desfazendo uma suposição dele', () => {
    const conversa = [
      cliente('Bom dia'),
      agente('Tenho hoje às 13h para sua coloração, pode ser?'),
      cliente('Não é coloração'),
    ];
    expect(voltasDaCliente(conversa).map((v) => v.tipo)).toEqual(['DISSE_QUE_NAO']);
  });

  it('conversa andando para frente não gera aviso nenhum', () => {
    const conversa = [
      cliente('Oi, queria fazer uma progressiva'),
      agente('Oi! São cinco progressivas aqui. Qual delas você quer?'),
      cliente('A sem formol'),
    ];
    expect(voltasDaCliente(conversa)).toEqual([]);
    expect(avisoDeVolta([])).toBe('');
  });

  it('conversa sem nenhuma fala dela não quebra', () => {
    expect(voltasDaCliente([])).toEqual([]);
    expect(voltasDaCliente([agente('Oi!')])).toEqual([]);
  });
});
