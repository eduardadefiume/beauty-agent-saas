import { describe, expect, it } from 'vitest';
import { payloadDaFicha, type Ficha } from './clientes/page';

// O bug que este teste tranca é o mesmo que já custou a classificação de preço:
// `site_save_client` SUBSTITUI o que recebe. Campo que a tela não devolve é
// campo que o banco apaga -- em silêncio, e só na próxima vez que alguém abrir
// a ficha.
//
// Agora esse campo é a classificação: como esta cliente se encaixa na régua que
// o salão cadastrou. Ela pode ter vindo do motor de foto, e ninguém vai
// desconfiar de que sumiu por causa de um salvamento de nome.

const COMPRIMENTO = '2982dcdb-ab36-45bb-a79f-dd03078d15cb';
const LONGO = '7bcf2059-a74f-48de-a33f-5150b099696f';
const VOLUME = 'c0ffee00-0000-4000-8000-000000000001';
const ALTO = 'c0ffee00-0000-4000-8000-000000000002';

function fichaCom(classifications: Ficha['classifications']): Ficha {
  return {
    profileId: 'p',
    contactId: 'c',
    displayName: 'Andressa',
    preferredName: 'Andressa',
    phone: '5516999999999',
    status: 'PRE_CADASTRO',
    pendencias: [],
    classifications,
    hasChemistry: null,
    chemistryKind: null,
    chemistryLastAt: null,
    chemistryFormol: null,
    hasColor: null,
    colorLastAt: null,
    toneWanted: null,
    notes: null,
    photoConsentGrantedAt: null,
    photoConsentRecordedBy: null,
    procedures: [],
    visits: [],
    photos: [],
  };
}

function classificacoesDoPayload(f: Ficha) {
  return payloadDaFicha(f).classifications as Array<{ dimensionId: string; optionId: string }>;
}

describe('ficha: a classificação volta para o banco em vez de sumir', () => {
  it('devolve o que o motor leu na foto', () => {
    const payload = classificacoesDoPayload(
      fichaCom([
        {
          dimensionId: COMPRIMENTO,
          dimensionName: 'Comprimento',
          optionId: LONGO,
          optionLabel: 'Longo',
          confidence: 0.92,
          source: 'AGENTE_FOTO',
          decidedAt: '2026-09-01T12:00:00Z',
        },
      ])
    );
    // Sem esta linha, salvar o nome da cliente apagaria a leitura da foto.
    expect(payload).toEqual([{ dimensionId: COMPRIMENTO, optionId: LONGO }]);
  });

  it('cabem quantas dimensões o salão criar, não duas', () => {
    // O motivo de a tabela existir: a ficha tinha duas gavetas fixas, e uma
    // terceira pergunta cadastrada pelo salão não teria onde ser gravada.
    const payload = classificacoesDoPayload(
      fichaCom([
        {
          dimensionId: COMPRIMENTO,
          dimensionName: 'Comprimento',
          optionId: LONGO,
          optionLabel: 'Longo',
          confidence: null,
          source: 'PESSOA',
          decidedAt: null,
        },
        {
          dimensionId: VOLUME,
          dimensionName: 'Volume',
          optionId: ALTO,
          optionLabel: 'Alto',
          confidence: null,
          source: 'PESSOA',
          decidedAt: null,
        },
      ])
    );
    expect(payload).toHaveLength(2);
    expect(payload.map((c) => c.dimensionId)).toEqual([COMPRIMENTO, VOLUME]);
  });

  it('ficha sem classificação manda lista vazia, não campo ausente', () => {
    // Ausente e vazio significam coisas diferentes no banco: ausente é "não
    // mexe", vazio é "apaga". Quem escolhe "não anotado" quer apagar.
    const payload = payloadDaFicha(fichaCom([]));
    expect(payload.classifications).toEqual([]);
    expect('classifications' in payload).toBe(true);
  });

  it('só id vai para o banco -- rótulo e confiança são de leitura', () => {
    const payload = classificacoesDoPayload(
      fichaCom([
        {
          dimensionId: COMPRIMENTO,
          dimensionName: 'Comprimento',
          optionId: LONGO,
          optionLabel: 'Longo',
          confidence: 0.92,
          source: 'AGENTE_FOTO',
          decidedAt: '2026-09-01T12:00:00Z',
        },
      ])
    );
    const primeira = payload[0];
    if (!primeira) throw new Error('o payload não devolveu nenhuma classificação');
    // Reenviar `source` deixaria a tela decidir quem respondeu, e o ponto todo
    // da regra é que quem grava pela tela é PESSOA, decidido no banco.
    expect(Object.keys(primeira).sort()).toEqual(['dimensionId', 'optionId']);
  });
});
