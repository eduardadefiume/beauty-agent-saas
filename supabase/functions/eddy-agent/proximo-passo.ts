// O CADASTRO NUNCA PARA SEM PRÓXIMO PASSO.
//
// 02/10, DEV, William-robô: ele respondeu "pode deixar o padrão" à pergunta do
// teste de mecha e o Eddy respondeu "Fechado, fica no modelo padrão." -- e
// mais nada. A pergunta da cor tinha saído no turno anterior, junto da outra,
// e o filtro de "não repita a pergunta, ele está em outro assunto" a engoliu.
// Mesmo buraco em "Feito. Mais alguma mudança?" -> "não".
//
// Se a resposta não tem pergunta nenhuma e o roteiro tem pendência, a próxima
// pergunta do roteiro entra no fim. Não entra se o dono adiou o assunto, se
// está no meio do sinal (bloqueado) ou se disse que vai parar agora.

import { temPergunta } from '../whatsapp-agent/uma-pergunta.ts';

const VAI_PARAR =
  /\b(por hoje|depois (eu )?(continuo|termino|vejo|falo|te falo|respondo)|falo depois|mais tarde|amanh[aã]|tenho que (ir|sair)|vou (parar|sair|atender)|agora n[aã]o (d[aá]|posso)|outra hora|to ocupad|t[oô] ocupad|estou ocupad)/i;

export function comProximoPasso(
  mensagens: string[],
  o: { proxima: string; leva: string; bloqueado: boolean }
): string[] {
  const proxima = (o.proxima ?? '').trim();
  if (!proxima || o.bloqueado || mensagens.length === 0) return mensagens;
  if (mensagens.some((m) => temPergunta(String(m ?? '')))) return mensagens;
  if (VAI_PARAR.test(o.leva ?? '')) return mensagens;
  return [...mensagens, proxima];
}
