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
  /\b(depois (eu )?(te )?(mando|envio)|(te )?(mando|envio) (depois|mais tarde|amanh)|por hoje|depois (eu )?(continuo|termino|vejo|falo|te falo|respondo)|falo depois|mais tarde|amanh[aã]|tenho que (ir|sair)|vou (parar|sair|atender)|agora n[aã]o (d[aá]|posso)|outra hora|to ocupad|t[oô] ocupad|estou ocupad)/i;

// 02/10, deslize 9: o acréscimo repetiu, palavra por palavra, a pergunta
// genérica da cor que ele já tinha respondido por áudio -- o refrão que a
// regra antiga evitava. Pergunta já feita não volta; se a etapa tem
// sub-perguntas ainda não feitas, vai a próxima delas.
const chave = (t: string) =>
  String(t ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9 ]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 60);

export function comProximoPasso(
  mensagens: string[],
  o: {
    proxima: string;
    leva: string;
    bloqueado: boolean;
    jaFeitas?: string[];
    alternativas?: string[];
  }
): string[] {
  if (o.bloqueado || mensagens.length === 0) return mensagens;
  if (mensagens.some((m) => temPergunta(String(m ?? '')))) return mensagens;
  if (VAI_PARAR.test(o.leva ?? '')) return mensagens;
  const feitas = (o.jaFeitas ?? []).map(chave).filter((f) => f.length >= 20);
  const bate = (f: string, k: string) => f.includes(k) || k.includes(f);
  // Pergunta feita lá atrás não volta (deslize 9). A ÚLTIMA pergunta do Eddy,
  // que ele interrompeu ("antes de regra, muda o sinal"), volta UMA vez.
  const jaFeita = (q: string) => {
    const k = chave(q);
    const vezes = feitas.filter((f) => bate(f, k)).length;
    if (vezes === 0) return false;
    const ultima = feitas[feitas.length - 1] ?? '';
    return !(vezes === 1 && bate(ultima, k));
  };
  const candidata = [o.proxima, ...(o.alternativas ?? [])]
    .map((q) => (q ?? '').trim())
    .find((q) => q && !jaFeita(q));
  return candidata ? [...mensagens, candidata] : mensagens;
}

// O FILTRO DE REFRÃO NUNCA APAGA A RESPOSTA INTEIRA.
//
// 02/10, deslize 10: "ja te falei no audio kkk" -> as duas bolhas da resposta
// falavam de fotos (assunto adiado) e o filtro apagou as duas. Resposta vazia
// virava "Isso aqui eu não consigo fazer por aqui. Já avisei a Eduarda" -- o
// dono largado no meio do cadastro por causa de um filtro de estilo.
export function semRefrao(mensagens: string[], ehRefrao: (t: string) => boolean): string[] {
  if (mensagens.length <= 1) return mensagens;
  const sobra = mensagens.filter((t) => !ehRefrao(t));
  return sobra.length > 0 ? sobra : mensagens;
}

// O PADRÃO DA COR NUMA MENSAGEM SÓ.
//
// 02/10, DEV: depois do áudio de cor, faltavam 9 perguntas técnicas (níveis,
// minutos, matização...), uma por vez -- e o Eddy já começou supondo "além do
// nível 2". Dono de salão responde "faço o normal". Mostra o padrão inteiro,
// e "pode ser" grava as 9 (aceitar_padrao_da_cor).
type PerguntaDeCor = { chave?: string; unidade?: string; sugestao?: number; pergunta?: string };

const ROTULO: Record<string, (v: number) => string> = {
  CLAREIA_SEM_DESCOLORIR: (v) => `a coloração clareia até ${v} níveis sem descolorir`,
  TESTE_A_PARTIR_DE: (v) => `teste de mecha a partir de ${v} níveis de clareamento`,
  MINUTOS_POR_NIVEL: (v) => `${v} min a mais por nível clareado`,
  REAIS_POR_NIVEL: (v) =>
    v > 0 ? `R$ ${v} a mais por nível clareado` : 'sem cobrar a mais por nível clareado',
  MINUTOS_PRE_PIGMENTACAO: (v) => `pré-pigmentação leva ${v} min`,
  REAIS_PRE_PIGMENTACAO: (v) => (v > 0 ? `pré-pigmentação R$ ${v}` : 'pré-pigmentação inclusa'),
  MINUTOS_MATIZACAO: (v) => `matização leva ${v} min`,
  REAIS_MATIZACAO: (v) => (v > 0 ? `matização R$ ${v}` : 'matização inclusa'),
  QUIMICA_EXIGE_TESTE: (v) =>
    v
      ? 'cabelo com química antiga sempre faz teste antes de cor'
      : 'química antiga não obriga teste',
};

export function padraoDaCor(perguntas: PerguntaDeCor[]): string {
  const itens = (perguntas ?? [])
    .filter((p) => p && typeof p.sugestao === 'number')
    .map((p) => {
      const rotulo = ROTULO[p.chave ?? ''];
      return rotulo
        ? rotulo(p.sugestao as number)
        : `${(p.pergunta ?? '').replace(/\?$/, '')}: ${p.sugestao}`;
    });
  if (itens.length === 0) return '';
  return (
    'Pro resto da cor eu uso o padrão da maioria dos salões: ' +
    itens.join('; ') +
    '. Pode ser assim, ou quer mudar algum?'
  );
}
