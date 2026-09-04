import { describe, expect, it } from 'vitest';
import { type ConversaParaEnviar, enviarConversas, fatiar } from '../lib/whatsapp-backup/enviar';
import type { ConversaDoBackup } from '../lib/whatsapp-backup/msgstore';

// O que este teste tranca: mandar o backup em pedaços sem perder nem dobrar.
//
// Dois erros aqui não aparecem na tela. Se `primeiroPedaco` vier marcado em
// todo lote, cada lote apaga o anterior e o dono fica com o final da conversa
// achando que importou tudo. Se não vier em nenhum, reimportar dobra o
// histórico — e reimportar é exatamente o que se faz quando não se tem certeza.

function conversa(chave: string, quantas: number): ConversaDoBackup {
  return {
    chaveExterna: chave,
    nome: chave,
    telefone: chave.split('@')[0] ?? null,
    ehGrupo: false,
    falas: Array.from({ length: quantas }, (_, i) => ({
      posicao: i,
      quem: (i % 2 === 0 ? 'CLIENTE' : 'DONO') as 'CLIENTE' | 'DONO',
      texto: `fala ${i}`,
      enviadaEm: null,
      midia: null,
    })),
  };
}

describe('fatiar o backup em lotes', () => {
  it('marca só o primeiro pedaço de cada conversa', () => {
    const lotes = fatiar([conversa('5516900000001@s.whatsapp.net', 25)], 10);
    const pedacos = lotes.flat();

    expect(pedacos).toHaveLength(3);
    expect(pedacos.map((p) => p.primeiroPedaco)).toEqual([true, false, false]);
  });

  it('não perde nem repete nenhuma fala ao cortar', () => {
    const original = conversa('5516900000001@s.whatsapp.net', 25);
    const todas = fatiar([original], 10)
      .flat()
      .flatMap((p) => p.falas);

    expect(todas.map((f) => f.posicao)).toEqual(original.falas.map((f) => f.posicao));
  });

  it('junta conversas curtas no mesmo lote em vez de uma requisição por cliente', () => {
    const lotes = fatiar(
      [
        conversa('5516900000001@s.whatsapp.net', 3),
        conversa('5516900000002@s.whatsapp.net', 4),
        conversa('5516900000003@s.whatsapp.net', 2),
      ],
      10
    );
    expect(lotes).toHaveLength(1);
    expect(lotes[0]).toHaveLength(3);
  });

  it('conversa vazia continua existindo do outro lado', () => {
    const vazia: ConversaDoBackup = {
      chaveExterna: '5516900000009@s.whatsapp.net',
      nome: 'so foto apagada',
      telefone: '5516900000009',
      ehGrupo: false,
      falas: [],
    };
    const pedacos = fatiar([vazia], 10).flat();
    expect(pedacos).toHaveLength(1);
    expect(pedacos[0]?.primeiroPedaco).toBe(true);
  });
});

describe('enviar', () => {
  it('conta conversa uma vez só, mesmo quando ela vai em três pedaços', async () => {
    const enviados: ConversaParaEnviar[][] = [];
    const andamento = await enviarConversas(
      [conversa('5516900000001@s.whatsapp.net', 25), conversa('5516900000002@s.whatsapp.net', 5)],
      async (lote) => {
        enviados.push(lote);
      },
      undefined,
      10
    );

    expect(andamento).toMatchObject({
      conversasEnviadas: 2,
      totalDeConversas: 2,
      mensagensEnviadas: 30,
      totalDeMensagens: 30,
    });
  });

  it('para no erro em vez de seguir e dizer que deu certo', async () => {
    let lotes = 0;
    await expect(
      enviarConversas(
        [conversa('5516900000001@s.whatsapp.net', 30)],
        async () => {
          lotes += 1;
          if (lotes === 2) throw new Error('a rede caiu');
        },
        undefined,
        10
      )
    ).rejects.toThrow('a rede caiu');
    expect(lotes).toBe(2);
  });
});
