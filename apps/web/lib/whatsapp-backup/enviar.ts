// MANDAR O BACKUP LIDO PARA O SALÃO, EM PEDAÇOS
//
// Dois anos de WhatsApp de um salão são dezenas de milhares de mensagens. Isso
// não cabe em uma requisição, e tentar mandar de uma vez é o jeito de descobrir
// o limite do servidor com o histórico do dono pela metade.
//
// Então vai em lotes. A regra que importa é `primeiroPedaco`: no lote que abre
// uma conversa, o servidor apaga o que já havia dela antes de gravar. É isso
// que faz reimportar o mesmo backup ser inofensivo em vez de dobrar tudo — e
// reimportar é o que qualquer pessoa faz quando não tem certeza se funcionou.

import type { ConversaDoBackup, FalaDoBackup } from './msgstore';

export type ConversaParaEnviar = {
  chave: string;
  nome: string;
  telefone: string | null;
  ehGrupo: boolean;
  primeiroPedaco: boolean;
  falas: FalaDoBackup[];
};

export type Andamento = {
  conversasEnviadas: number;
  totalDeConversas: number;
  mensagensEnviadas: number;
  totalDeMensagens: number;
};

// Um lote fica bem abaixo do limite de corpo da rota. Mensagem de salão é
// curta, mas explicação técnica do dono não é, e é justamente ela que a gente
// quer inteira.
export const FALAS_POR_LOTE = 500;

export function fatiar(
  conversas: ConversaDoBackup[],
  falasPorLote = FALAS_POR_LOTE
): ConversaParaEnviar[][] {
  const lotes: ConversaParaEnviar[][] = [];
  let lote: ConversaParaEnviar[] = [];
  let cabem = falasPorLote;

  const fechar = () => {
    if (lote.length > 0) lotes.push(lote);
    lote = [];
    cabem = falasPorLote;
  };

  for (const conversa of conversas) {
    let inicio = 0;
    let abrindo = true;

    // Conversa vazia ainda precisa existir do outro lado, ou some da lista sem
    // explicação.
    if (conversa.falas.length === 0) {
      if (cabem <= 0) fechar();
      lote.push({
        chave: conversa.chaveExterna,
        nome: conversa.nome,
        telefone: conversa.telefone,
        ehGrupo: conversa.ehGrupo,
        primeiroPedaco: true,
        falas: [],
      });
      cabem -= 1;
      continue;
    }

    while (inicio < conversa.falas.length) {
      if (cabem <= 0) fechar();
      const pedaco = conversa.falas.slice(inicio, inicio + cabem);
      lote.push({
        chave: conversa.chaveExterna,
        nome: conversa.nome,
        telefone: conversa.telefone,
        ehGrupo: conversa.ehGrupo,
        primeiroPedaco: abrindo,
        falas: pedaco,
      });
      cabem -= pedaco.length;
      inicio += pedaco.length;
      abrindo = false;
    }
  }

  fechar();
  return lotes;
}

export async function enviarConversas(
  conversas: ConversaDoBackup[],
  enviarLote: (lote: ConversaParaEnviar[]) => Promise<void>,
  aoAndar?: (andamento: Andamento) => void,
  falasPorLote = FALAS_POR_LOTE
): Promise<Andamento> {
  const totalDeMensagens = conversas.reduce((soma, c) => soma + c.falas.length, 0);
  const andamento: Andamento = {
    conversasEnviadas: 0,
    totalDeConversas: conversas.length,
    mensagensEnviadas: 0,
    totalDeMensagens,
  };

  for (const lote of fatiar(conversas, falasPorLote)) {
    await enviarLote(lote);
    andamento.conversasEnviadas += lote.filter((c) => c.primeiroPedaco).length;
    andamento.mensagensEnviadas += lote.reduce((soma, c) => soma + c.falas.length, 0);
    aoAndar?.({ ...andamento });
  }

  return andamento;
}
