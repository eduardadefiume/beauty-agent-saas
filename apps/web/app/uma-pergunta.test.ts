import { describe, expect, it } from 'vitest';

import {
  ateTresBolhas,
  umaPerguntaPorVez,
} from '../../../supabase/functions/whatsapp-agent/uma-pergunta';

// 02/10, DEV, William-robô: "Você tem um jeito próprio de explicar isso pra
// cliente?" + "Agora, cor e mechas: prefere fotos ou áudio?" na mesma resposta.
// Ele responde "pode ser o padrão" e uma das duas some.
describe('uma pergunta por vez (02/10)', () => {
  it('caso real: a segunda pergunta sai', () => {
    expect(
      umaPerguntaPorVez([
        'Anotei: teste de mecha no mesmo dia, dentro do tempo das luzes, sem cobrar à parte.',
        'Você tem um jeito próprio de explicar isso pra cliente, ou posso deixar na nossa explicação padrão?',
        'Agora, cor e mechas: prefere me mandar fotos de trabalhos seus (eu reconheço o tom) ou um áudio explicando como você trabalha com cor?',
      ])
    ).toEqual([
      'Anotei: teste de mecha no mesmo dia, dentro do tempo das luzes, sem cobrar à parte.',
      'Você tem um jeito próprio de explicar isso pra cliente, ou posso deixar na nossa explicação padrão?',
    ]);
  });

  it.each([
    [['Anotei.', 'Que dias e horários o salão atende?']],
    [['Qual a chave Pix pra cliente pagar o sinal, e em nome de quem aparece?']],
    // par de propósito na MESMA bolha (pergunta do prazo do sinal)
    [
      [
        'Quanto tempo a cliente tem pra pagar? O normal é 24h. E se ela marcar de um mês pro outro, quer dar mais tempo?',
        'Só lembrando: o prazo nunca passa de 2h antes do horário.',
      ],
    ],
    [['Sinal ligado!', 'Já vale: R$ 50 pra química.']],
    [['Conecta aqui: https://x.com/agenda?c=AB12&t=1', 'Me avisa quando terminar?']],
    [[]],
    [['Posso ligar o sinal?']],
  ])('não mexe: %j', (msgs) => {
    expect(umaPerguntaPorVez(msgs)).toEqual(msgs);
  });

  it('aviso depois da pergunta fica; segunda pergunta sai', () => {
    expect(
      umaPerguntaPorVez([
        'Qual o nome do salão?',
        'Só pra saber: o endereço eu pego depois.',
        'E o Instagram?',
      ])
    ).toEqual(['Qual o nome do salão?', 'Só pra saber: o endereço eu pego depois.']);
  });

  it('na bolha seguinte, só a frase da pergunta sai', () => {
    expect(
      umaPerguntaPorVez([
        'Quanto custa o corte?',
        'Anotei a escova em 40 min. E a hidratação, quanto tempo?',
      ])
    ).toEqual(['Quanto custa o corte?', 'Anotei a escova em 40 min.']);
  });

  it('pergunta com emoji, ?! e link depois', () => {
    expect(
      umaPerguntaPorVez(['Ficou bom? 😊', 'Quer que eu já ligue?!', 'Link: https://a.b/c?d=1'])
    ).toEqual(['Ficou bom? 😊', 'Link: https://a.b/c?d=1']);
  });

  it('link com ? não conta como pergunta', () => {
    const msgs = ['Abre: https://a.b/c?d=1 e entra com sua conta.', 'Conseguiu?'];
    expect(umaPerguntaPorVez(msgs)).toEqual(msgs);
  });
});

describe('atendente: cumprimento não é pergunta; a segunda pergunta sai (02/10)', () => {
  it('formol + horário: o horário fica para o próximo turno, o preço fica', () => {
    expect(
      umaPerguntaPorVez([
        'Você sabe se essa química tinha formol?',
        'O teste de mecha fica R$ 20,00. Tenho quarta 07/10 às 9h com o William, pode ser?',
      ])
    ).toEqual(['Você sabe se essa química tinha formol?', 'O teste de mecha fica R$ 20,00.']);
  });
  it.each([
    [
      [
        'Oi, boa tarde! Tudo bem?',
        'Corte com escova está R$ 110,00.',
        'Tenho sábado às 9h, pode ser? E qual o seu nome?',
      ],
    ],
    [
      [
        'Oi, Daniela! Tudo bem?',
        'Corte com escova está R$ 100,00.',
        'Tenho sexta 09/10 às 10h, pode ser?',
      ],
    ],
    [['Oi! Tudo bom?', 'O corte fica R$ 110,00.', 'Qual o seu nome?']],
    [['Oii, td bem??', 'Qual serviço você quer?']],
  ])('não mexe: %j', (msgs) => {
    expect(umaPerguntaPorVez(msgs)).toEqual(msgs);
  });
});

describe('no máximo 3 bolhas, sem perder nada (02/10)', () => {
  it('a 4ª junta na 3ª', () => {
    expect(ateTresBolhas(['a', 'b', 'c', 'Tenho sexta 10h, pode ser?'])).toEqual([
      'a',
      'b',
      'c\n\nTenho sexta 10h, pode ser?',
    ]);
  });
  it.each([[[]], [['a']], [['a', 'b', 'c']]])('não mexe: %j', (m) => {
    expect(ateTresBolhas(m)).toEqual(m);
  });
});

describe('"?" dentro de aspas é texto citado, não pergunta (02/10)', () => {
  it('caso real: o texto do dono com "tá?" não come a pergunta do lembrete', () => {
    const msgs = [
      '"Oi {nome}! Seu horário tá confirmado dia {data} às {hora}. Chega 5 min antes tá? Qualquer coisa me chama"',
      'Quer que eu lembre a cliente na véspera? Hoje o lembrete está desligado.',
    ];
    expect(umaPerguntaPorVez(msgs)).toEqual(msgs);
  });
  it.each([
    [['Fica assim: “Chega antes, tá?”', 'Quer mudar algo?']],
    [["Fica assim: 'Tudo certo? Te espero!'", 'Pode ser?']],
    [['Fica assim: «Vem mesmo?»', 'Confirma?']],
  ])('aspas de todo tipo: %j', (msgs) => {
    expect(umaPerguntaPorVez(msgs)).toEqual(msgs);
  });
  it('fora das aspas continua valendo', () => {
    expect(umaPerguntaPorVez(['"Chega antes, tá?" Pode ser?', 'E o Instagram?'])).toEqual([
      '"Chega antes, tá?" Pode ser?',
    ]);
  });
});
