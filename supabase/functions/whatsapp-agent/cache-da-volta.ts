// CACHE ENTRE AS VOLTAS DO MESMO TURNO (Eddy e atendente).
//
// 02/10, custo medido: o Eddy gastava US$ 0,066 por resposta, e ~70% disso era
// texto reenviado SEM cache -- a mensagem do turno (dados + instruções, ~7 mil
// tokens) ia inteira em cada volta (2,3 voltas por resposta). Uma marca de
// cache na última mensagem faz a volta seguinte ler esse trecho a ~10% do
// preço. O texto que o modelo lê não muda em nada.
//
// Só a ÚLTIMA mensagem carrega a marca (máx. 4 por pedido; o system já usa 1
// ou 2). TTL de 5 minutos: as voltas de um turno são segundos.

type Bloco = { type?: string; cache_control?: unknown; [k: string]: unknown };
type Mensagem = { role: string; content: string | Bloco[] };

const MARCA = { type: 'ephemeral' as const };

function semMarca(blocos: Bloco[]): Bloco[] {
  if (!blocos.some((b) => b && 'cache_control' in b)) return blocos;
  return blocos.map((b) => {
    if (!b || !('cache_control' in b)) return b;
    const { cache_control: _fora, ...resto } = b;
    return resto as Bloco;
  });
}

export function comCacheNaUltima<M extends Mensagem>(mensagens: M[]): M[] {
  if (!Array.isArray(mensagens) || mensagens.length === 0) return mensagens;
  const ultima = mensagens.length - 1;
  return mensagens.map((m, i) => {
    if (i !== ultima) {
      return Array.isArray(m.content) ? ({ ...m, content: semMarca(m.content) } as M) : m;
    }
    if (typeof m.content === 'string') {
      if (m.content.length === 0) return m;
      return { ...m, content: [{ type: 'text', text: m.content, cache_control: MARCA }] } as M;
    }
    const blocos = semMarca(m.content);
    // Marca no último bloco que aceita cache (texto, tool_result, imagem...).
    for (let j = blocos.length - 1; j >= 0; j--) {
      const t = blocos[j]?.type;
      if (t === 'thinking' || t === 'redacted_thinking') continue;
      const copia = blocos.slice();
      copia[j] = { ...blocos[j], cache_control: MARCA };
      return { ...m, content: copia } as M;
    }
    return { ...m, content: blocos } as M;
  });
}
