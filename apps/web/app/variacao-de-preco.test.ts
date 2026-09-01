import { describe, expect, it } from 'vitest';
import { normalize } from './configurator-real';

// O bug que este teste tranca:
//
// app.service_variations sempre teve classification_values -- é ele que diz A
// QUAL CASO um preço se aplica (comprimento longo, volume alto). A tela lia
// só nome e preço. Como o salvamento devolve o objeto de configuração INTEIRO,
// o campo que a tela não lia era o campo que o banco apagava, a cada gravação,
// em silêncio.
//
// Então o teste não é sobre formatar dado: é sobre não perder dado num
// caminho de ida e volta.

const COMPRIMENTO = '2982dcdb-ab36-45bb-a79f-dd03078d15cb';
const LONGO = '7bcf2059-a74f-48de-a33f-5150b099696f';

// Pega a primeira variação já garantindo que ela existe: se o normalize deixar
// de devolvê-la, o teste falha com uma frase legível em vez de um erro de nulo.
function primeiraVariacao(config: ReturnType<typeof normalize>) {
  const variacao = config.services[0]?.variations[0];
  if (!variacao) throw new Error('o normalize não devolveu nenhuma variação');
  return variacao;
}

function carregadoCom(variations: unknown) {
  return {
    tenant: { id: 't', name: 'Salão' },
    unit: { id: 'u', name: 'Unidade', timezone: 'America/Sao_Paulo' },
    draft: { id: 'd', revision: 1, status: 'DRAFT' },
    configuration: {
      unit: { name: 'Unidade', timezone: 'America/Sao_Paulo' },
      services: [{ name: 'Mechas morena iluminada', variations }],
    },
    readiness: [],
  } as unknown as Parameters<typeof normalize>[0];
}

describe('variação de preço: a classificação sobrevive ao carregamento', () => {
  it('mantém o caso a que o preço se aplica', () => {
    const config = normalize(
      carregadoCom([
        {
          name: 'Cabelo longo',
          price_minor: 58000,
          classification_values: { [COMPRIMENTO]: LONGO },
        },
      ])
    );

    const variacao = primeiraVariacao(config);
    expect(variacao.name).toBe('Cabelo longo');
    expect(variacao.priceMinor).toBe(58000);
    // Sem esta linha, salvar apagava a classificação no banco.
    expect(variacao.classificationValues).toEqual({ [COMPRIMENTO]: LONGO });
  });

  it('variação sem classificação vira objeto vazio, não indefinido', () => {
    const config = normalize(
      carregadoCom([{ name: 'Padrão', price_minor: 43000, classification_values: {} }])
    );
    expect(primeiraVariacao(config).classificationValues).toEqual({});
  });

  it('descarta lixo em vez de quebrar a tela', () => {
    // Escrita antiga pode ter deixado qualquer coisa no jsonb. O que não tem a
    // forma { pergunta: resposta } não entra -- e não derruba o configurador.
    const config = normalize(
      carregadoCom([
        {
          name: 'Bagunça',
          price_minor: null,
          classification_values: { [COMPRIMENTO]: LONGO, ruim: 42, pior: null, vazio: '' },
        },
      ])
    );
    expect(primeiraVariacao(config).classificationValues).toEqual({
      [COMPRIMENTO]: LONGO,
    });
  });

  it('aceita o formato camelCase, caso a leitura mude de nome', () => {
    const config = normalize(
      carregadoCom([
        { name: 'Camel', price_minor: 1, classificationValues: { [COMPRIMENTO]: LONGO } },
      ])
    );
    expect(primeiraVariacao(config).classificationValues).toEqual({
      [COMPRIMENTO]: LONGO,
    });
  });
});
