import { describe, expect, it } from 'vitest';

import { corpoDeTemplate } from '../../../supabase/functions/whatsapp-sender/corpo-de-template';

// 23/09/2026. O lembrete de vespera nunca saiu -- nao por causa da Meta, mas
// porque o worker nao sabia montar o corpo de um template. Estes testes existem
// para que a proxima pessoa que mexer aqui descubra o erro antes da cliente.

describe('corpoDeTemplate', () => {
  it('monta a forma que a Cloud API espera', () => {
    const corpo = corpoDeTemplate({
      template_name: 'lembrete_vespera',
      template_language: 'pt_BR',
      template_params: ['Rayana', '24/09', '14:00', 'Salao do William'],
    });

    expect(corpo).toEqual({
      type: 'template',
      template: {
        name: 'lembrete_vespera',
        language: { code: 'pt_BR' },
        components: [
          {
            type: 'body',
            parameters: [
              { type: 'text', text: 'Rayana' },
              { type: 'text', text: '24/09' },
              { type: 'text', text: '14:00' },
              { type: 'text', text: 'Salao do William' },
            ],
          },
        ],
      },
    });
  });

  // A recusa mais cara de diagnosticar: a Meta devolve 131008 sem dizer qual
  // parametro. Nome digitado por gente vem com espaco duplo o tempo todo.
  it('achata espaco duplo, tabulacao e quebra de linha', () => {
    const corpo = corpoDeTemplate({
      template_name: 'lembrete_vespera',
      template_language: 'pt_BR',
      template_params: ['  Ana   Paula \n da Silva\t'],
    });

    const template = corpo.template as {
      components: Array<{ parameters: Array<{ text: string }> }>;
    };
    expect(template.components[0].parameters[0].text).toBe('Ana Paula da Silva');
  });

  // Parametro vazio nao estraga so aquele campo: derruba a mensagem inteira.
  // Melhor estourar aqui, com o numero do parametro, do que no log da Meta.
  it('recusa parametro vazio dizendo qual e', () => {
    expect(() =>
      corpoDeTemplate({
        template_name: 'lembrete_vespera',
        template_language: 'pt_BR',
        template_params: ['Rayana', '   ', '14:00'],
      })
    ).toThrow(/parametro 2 .* vazio/);
  });

  it('recusa template sem nome de modelo', () => {
    expect(() =>
      corpoDeTemplate({
        template_name: '  ',
        template_language: 'pt_BR',
        template_params: [],
      })
    ).toThrow(/sem nome de modelo/);
  });

  // Modelo sem variavel nao pode levar `components`: lista vazia e recusada.
  it('omite components quando o modelo nao tem variavel', () => {
    const corpo = corpoDeTemplate({
      template_name: 'aviso_simples',
      template_language: 'pt_BR',
      template_params: [],
    });

    expect(corpo.template).toEqual({
      name: 'aviso_simples',
      language: { code: 'pt_BR' },
    });
  });

  it('cai no pt_BR quando a coluna de idioma vem vazia', () => {
    const corpo = corpoDeTemplate({
      template_name: 'lembrete_vespera',
      template_language: null,
      template_params: ['Rayana'],
    });

    expect((corpo.template as { language: { code: string } }).language.code).toBe('pt_BR');
  });

  // template_params e jsonb: pode chegar null de uma linha antiga, e nesse caso
  // o certo e mandar um template sem variavel, nao estourar o lote inteiro.
  it('trata params nao-lista como ausencia de parametro', () => {
    const corpo = corpoDeTemplate({
      template_name: 'aviso_simples',
      template_language: 'pt_BR',
      template_params: null,
    });

    expect(corpo.template).not.toHaveProperty('components');
  });
});
