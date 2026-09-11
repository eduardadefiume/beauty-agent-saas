import { describe, expect, it } from 'vitest';

import {
  centavosDoTexto,
  precosDoNegocio,
  precosSemLastro,
  valoresEmCentavos,
} from '../../../supabase/functions/whatsapp-agent/preco-com-lastro';

// O que este teste tranca: nenhum valor em reais sai para a cliente sem estar
// escrito em algum lugar dos dados do salao.
//
// A auditoria nomeou bem por que este e o defeito mais caro do produto: preco
// inventado "nao e invencao, e pior de um jeito especifico: e um numero real,
// plausivel, verificavel na tela - e sem nenhuma fonte de verdade por tras".
// A cliente anota e cobra na cadeira. O salao honra ou desmente na frente dela.
//
// O contexto abaixo e o do salao-piloto de verdade, no dia em que este teste
// foi escrito: `priceMinor` null no catalogo inteiro, e os UNICOS numeros que o
// agente enxerga saindo da leitura de uma arte de status. Os precos existiam no
// rascunho do configurador; nunca tinham sido publicados, e o agente le a
// versao publicada.

const ARTE_DO_PILOTO = [
  {
    id: '2e30d760-8ecd-4217-8906-2acc95845469',
    desde: '2026-08-28',
    conteudo:
      'Texto encontrado na imagem:\n- Logo: "WB WILLIAM BRANCO hair & co."\n- Título: "MORENA iluminada"\n- "A PARTIR DE R$ 430,00"\n- "INCLUSO: HIDRATAÇÃO / RECONSTRUÇÃO / CORTE / FINALIZAÇÃO COM ESCOVA E BABYLISS"\n- "INCLUI TESTE"\n- "Teste e avaliação em dias separados tem um custo de R$ 20,00"\n- "CABELOS LONGOS, VOLUMOSOS E COM CORREÇÃO DE COR precisam ser avaliados."',
    ownerNote: null,
    confirmadaPorMaisDeUma: true,
  },
];

const ESTAVEL_DO_PILOTO = {
  catalog: [
    {
      id: '9bbe3364-eaeb-48aa-a23c-0084d132b211',
      name: 'Botox capilar',
      currency: 'BRL',
      priceMinor: null,
      description: 'Cabelo médio.',
      durationMinutes: 140,
      requiresStrandTest: false,
    },
  ],
  statusArts: ARTE_DO_PILOTO,
  policies: [],
};

const VOLATIL_VAZIO = { client: { isKnown: false }, ownerAnswers: [], history: [] };

describe('ler um valor escrito em portugues', () => {
  it('le as formas que dono de salao escreve', () => {
    expect(centavosDoTexto('430')).toBe(43000);
    expect(centavosDoTexto('430,00')).toBe(43000);
    expect(centavosDoTexto('430,5')).toBe(43050);
    expect(centavosDoTexto('1.250')).toBe(125000);
    expect(centavosDoTexto('1.250,90')).toBe(125090);
  });

  // O ponto so parece ambiguo: separador de milhar vem sempre com tres digitos
  // atras, decimal vem com um ou dois. Contar resolve sem chute.
  it('separa milhar de decimal pelo numero de digitos', () => {
    expect(centavosDoTexto('1.250')).toBe(125000);
    expect(centavosDoTexto('430.50')).toBe(43050);
  });

  it('devolve null para o que nao da para ler com certeza', () => {
    expect(centavosDoTexto('')).toBeNull();
    expect(centavosDoTexto('cento e vinte')).toBeNull();
    expect(centavosDoTexto('12,345')).toBeNull();
  });
});

describe('achar dinheiro no meio do texto', () => {
  it('acha com o simbolo na frente e com a palavra atras', () => {
    expect(valoresEmCentavos('fica R$ 120 no cabelo médio').map((v) => v.centavos)).toEqual([
      12000,
    ]);
    expect(valoresEmCentavos('fica R$120,00').map((v) => v.centavos)).toEqual([12000]);
    expect(valoresEmCentavos('sai 180 reais').map((v) => v.centavos)).toEqual([18000]);
  });

  // Sem exigir R$ ou "reais", "14:30" e "3 sessoes" virariam preco e toda
  // resposta com horario cairia na trava. Uma trava que dispara sempre e
  // desligada na primeira semana.
  it('nao confunde horario, quantidade e porcentagem com preco', () => {
    expect(valoresEmCentavos('consigo sábado às 14:30')).toEqual([]);
    expect(valoresEmCentavos('são 3 sessões, 2 horas cada')).toEqual([]);
    expect(valoresEmCentavos('tem 20% de desconto')).toEqual([]);
    expect(valoresEmCentavos('me chama no 16 98106-4232')).toEqual([]);
  });
});

describe('de onde vem o lastro', () => {
  it('junta as cinco fontes que sao a voz do salao', () => {
    const conhecidos = precosDoNegocio(
      {
        catalog: [{ priceMinor: 12000 }],
        statusArts: ARTE_DO_PILOTO,
        policies: [{ texto: 'Sinal de R$ 50,00 para quimica.' }],
      },
      {
        client: { lastVisits: [{ on: '2026-07-02', what: 'Corte', amountMinor: 9000 }] },
        ownerAnswers: [{ question: 'quanto fica a escova?', answer: 'fala 70 reais' }],
      }
    );

    expect(conhecidos.has(12000)).toBe(true); // catalogo
    expect(conhecidos.has(43000)).toBe(true); // arte do status
    expect(conhecidos.has(2000)).toBe(true); // arte do status, o teste em dia separado
    expect(conhecidos.has(5000)).toBe(true); // policies
    expect(conhecidos.has(9000)).toBe(true); // o que ela pagou da outra vez
    expect(conhecidos.has(7000)).toBe(true); // a dona respondendo nesta conversa
  });

  // "Me falaram que era 300" nao e o salao falando. Se a mensagem da cliente
  // virasse lastro, bastaria ela citar um numero para o agente poder confirma-lo.
  it('o que a cliente escreveu nao vira lastro', () => {
    const conhecidos = precosDoNegocio(ESTAVEL_DO_PILOTO, {
      ...VOLATIL_VAZIO,
      history: [{ direction: 'INBOUND', text: 'uma amiga falou que era R$ 300' }],
    });
    expect(conhecidos.has(30000)).toBe(false);
  });
});

describe('o que sai e o que fica preso', () => {
  const conhecidos = precosDoNegocio(ESTAVEL_DO_PILOTO, VOLATIL_VAZIO);

  it('deixa passar o valor que o salao publicou', () => {
    expect(precosSemLastro(['a morena iluminada sai a partir de R$ 430'], conhecidos)).toEqual([]);
    expect(precosSemLastro(['o teste em dia separado custa R$ 20,00'], conhecidos)).toEqual([]);
  });

  // O caso da auditoria, inteiro: catalogo sem preco nenhum, e o agente
  // devolvendo um numero plausivel que nao esta em lugar nenhum.
  it('prende o numero que nasceu no modelo', () => {
    const soltos = precosSemLastro(['o botox capilar fica R$ 180'], conhecidos);
    expect(soltos.map((s) => s.centavos)).toEqual([18000]);
    expect(soltos[0]!.trecho).toBe('R$ 180');
  });

  it('prende tambem quando o numero vem sem simbolo', () => {
    expect(precosSemLastro(['fica 250 reais'], conhecidos).map((s) => s.centavos)).toEqual([25000]);
  });

  // Corte 120 + escova 80 e o agente escrevendo "fica R$ 200". A soma nao esta
  // em lugar nenhum, e isso e de proposito: pacote e condicao comercial, e o
  // proprio prompt ja proibe preco "comparado com outro servico". Quem fecha
  // pacote e a dona.
  it('soma de dois precos cadastrados nao passa', () => {
    const comCatalogo = precosDoNegocio(
      { catalog: [{ priceMinor: 12000 }, { priceMinor: 8000 }] },
      VOLATIL_VAZIO
    );
    expect(precosSemLastro(['corte e escova fica R$ 120'], comCatalogo)).toEqual([]);
    expect(
      precosSemLastro(['os dois juntos ficam R$ 200'], comCatalogo).map((s) => s.centavos)
    ).toEqual([20000]);
  });

  it('varre todos os baloes da resposta, nao so o primeiro', () => {
    const soltos = precosSemLastro(
      ['a morena iluminada sai a partir de R$ 430', 'e o botox fica R$ 180'],
      conhecidos
    );
    expect(soltos.map((s) => s.centavos)).toEqual([18000]);
  });

  it('resposta sem numero nenhum passa direto', () => {
    expect(precosSemLastro(['oi, tudo bem? me conta do seu cabelo'], conhecidos)).toEqual([]);
  });
});
