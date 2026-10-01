// O COMPROVANTE DO SINAL NÃO CONFIRMA NADA SOZINHO.
//
// 01/10: a cliente manda o comprovante e quem confirma é o dono, depois de
// ver o Pix na conta (app.sinal_dono_respondeu). Até lá a atendente só pode
// dizer que recebeu e que o salão vai conferir. "Prontinho, confirmado!" na
// hora do comprovante é promessa que o dono pode desmentir: Pix agendado,
// valor errado, comprovante de outra pessoa.

const CONFIRMA =
  /\b(confirmad[oa]|t[aá] confirmad|est[aá] confirmad|garantid[oa]|t[aá] marcad|est[aá] marcad|agendad[oa]|prontinho|tudo certo)\b/i;
const ESPERA =
  /\b(assim que|quando (o sal[aã]o|eles?|o \w+) (confirmar|conferir|responder)|vai conferir|v[aã]o conferir|conferir|aguard)/i;

/** Tira das bolhas qualquer "confirmado" antes do dono e garante o texto certo. */
export function semConfirmarAntesDoDono(bolhas: string[], textoCerto: string): string[] {
  const limpas = bolhas.filter((b) => {
    const t = String(b ?? '');
    return !(CONFIRMA.test(t) && !ESPERA.test(t));
  });
  // 01/10: o modelo partiu a frase em dois balões ("Recebi..." / "...vai
  // conferir") e a frase certa entrou de novo na frente: saiu duplicada.
  // Vale a resposta inteira, não um balão só.
  const tudo = limpas.join(' ');
  const jaDisse = /receb/i.test(tudo) && ESPERA.test(tudo);
  return jaDisse ? limpas : [textoCerto, ...limpas];
}

// CRÉDITO DE SINAL. Ela pagou um sinal depois do prazo; a reserva nova é paga
// com ele no banco (app.sinal_credito_usa) e já nasce confirmada. A resposta
// da agenda ainda diz PENDING_SIGNAL (foi escrita antes do gatilho), então
// quem decide se vai cartão de sinal é o crédito, não o status.
export type CreditoDaReserva = { usado?: boolean; jeito?: string; confirmado?: boolean };

export function reservaPedeSinal(
  statusDaAgenda: string | undefined,
  credito: CreditoDaReserva
): boolean {
  const pagaComCredito = !!credito.usado && credito.jeito === 'USADO' && !!credito.confirmado;
  return statusDaAgenda === 'PENDING_SIGNAL' && !pagaComCredito;
}
