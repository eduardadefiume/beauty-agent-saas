// O QUE A TRAVA SEGUROU VIRA AVISO NO WHATSAPP DA OPERADORA.
//
// 02/10/2026: as travas do código (preço sem base, "agendei" sem reserva,
// resposta quebrada ou vazia) já impediam o erro de chegar à cliente, mas
// ficavam só no log da função. Um erro do modelo que ninguém vê não é
// corrigido. Aqui sai, de cada turno, no máximo UM alerta, com tudo o que
// aconteceu nele e o suficiente para achar a conversa.

export type AlertaDoTurno = { tipo: 'RESPOSTA_BLOQUEADA' | 'PASSOU_PARA_PESSOA'; detalhe: string };

export function alertaDoTurno(t: {
  acaoDoModelo: 'REPLY' | 'ASK_OWNER' | 'HANDOFF';
  acaoFinal: 'REPLY' | 'ASK_OWNER' | 'HANDOFF';
  textos: string[];
  precosSemBase: string[];
  afirmouSemReserva: boolean;
  respostaQuebrada: boolean;
  perguntaAoDono?: string;
  motivo?: string;
  conversa?: string;
}): AlertaDoTurno | null {
  const travas: string[] = [];
  if (t.respostaQuebrada) travas.push('resposta do modelo veio quebrada');
  if (t.afirmouSemReserva) travas.push('disse que marcou/cancelou sem ter feito');
  if (t.precosSemBase.length > 0) travas.push('preço sem base: ' + t.precosSemBase.join(', '));
  if (t.acaoDoModelo === 'REPLY' && t.textos.length === 0) travas.push('resposta vazia');
  if (t.acaoDoModelo === 'ASK_OWNER' && (t.perguntaAoDono ?? '').trim().length < 3) {
    travas.push('quis perguntar à dona sem escrever a pergunta');
  }

  const onde = t.conversa ? ` [conversa ${t.conversa}]` : '';
  const curto = (s: string, n: number) => {
    const limpo = s.replace(/\s+/g, ' ').trim();
    return limpo.length > n ? limpo.slice(0, n - 1) + '…' : limpo;
  };

  if (travas.length > 0) {
    const escrito =
      t.textos.length > 0 ? ` | Ela tinha escrito: "${curto(t.textos.join(' / '), 300)}"` : '';
    return {
      tipo: 'RESPOSTA_BLOQUEADA',
      detalhe: curto(travas.join('; ') + escrito + onde, 780),
    };
  }

  if (t.acaoFinal === 'HANDOFF') {
    return {
      tipo: 'PASSOU_PARA_PESSOA',
      detalhe: curto((t.motivo?.trim() || 'sem motivo escrito') + onde, 780),
    };
  }

  return null;
}

// O ENVIO RECUSADO NÃO PODE PASSAR POR RESPOSTA DADA (07/10).
//
// O Eddy respondeu o "o 1" do William cinco dias depois (o crédito tinha
// acabado). A janela de 24h já tinha fechado, enqueue_outbound_message
// devolveu {ok:false, reason:'SERVICE_WINDOW_CLOSED'} e o código marcou
// REPLY sem olhar. Para o dono: silêncio. Aqui, cada resultado de envio é
// conferido; duplicado é sucesso (a mensagem já está na fila).
export function envioRecusado(resultados: unknown[]): string | null {
  const motivos: string[] = [];
  for (const r of resultados) {
    const x = (r ?? {}) as { ok?: unknown; reason?: unknown };
    if (x.ok === true) continue;
    motivos.push(typeof x.reason === 'string' && x.reason ? x.reason : 'SEM_RESPOSTA_DO_BANCO');
  }
  if (motivos.length === 0) return null;
  return `${motivos.length} de ${resultados.length} mensagens não saíram: ${[...new Set(motivos)].join(', ')}`;
}
