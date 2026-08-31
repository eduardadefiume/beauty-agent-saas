'use client';

// Tela do Agente: as regras do salão e as artes que ele leu.
//
// POR QUE ESTA TELA EXISTE. Até hoje, escrever uma regra para o agente era
// tarefa de quem tem acesso ao banco. Isso significa que a dona não conseguia
// consertar o próprio atendimento sozinha — e que uma regra errada ficava
// invisível para ela. Em 31/08 o agente passou a cumprimentar em toda resposta
// ("Oi, Eduarda!" no meio da conversa) porque uma regra dizia exatamente isso.
// A regra estava lá, escrita, e a única pessoa que podia lê-la ou corrigi-la
// não era a dona do salão. Uma regra que ninguém do negócio consegue ver não é
// uma regra do negócio.
//
// DUAS COISAS DIFERENTES, NA MESMA TELA:
//
//   REGRAS  — o que a dona manda o agente fazer. Texto em português, agrupado
//             por assunto. É a voz do salão.
//   ARTES   — o que o agente LEU nos status que a cliente respondeu. Não é
//             editável: é o que ele entendeu. A dona corrige por cima com uma
//             observação, ou aposenta a arte quando a promoção acaba.
//
// FORA DO CICLO DE PUBLICAÇÃO, de propósito. A configuração congela quando
// está no ar para não mudar debaixo de um atendimento. Uma regra é o oposto:
// quando a dona vê o agente errando, ela precisa corrigir agora, e a correção
// tem que valer na próxima mensagem.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import styles from './agente.module.css';

type Politica = {
  id: string;
  topic: string;
  title: string;
  body: string;
  status: string;
  position: number;
  updatedAt: string | null;
};

type Arte = {
  id: string;
  source: string;
  understanding: string | null;
  ownerNote: string | null;
  retired: boolean;
  timesSeen: number | null;
  firstSeenOn: string | null;
  lastSeenAt: string | null;
};

type Workspace = { tenantId: string; tenantName: string; timezone: string };

type Aba = 'REGRAS' | 'ARTES';

// Uma regra em edição. `id` vazio é regra nova, que ainda não existe no banco.
type Rascunho = {
  id: string;
  topic: string;
  title: string;
  body: string;
  status: string;
  position: number;
};

const RASCUNHO_VAZIO: Rascunho = {
  id: '',
  topic: 'VOZ',
  title: '',
  body: '',
  status: 'ACTIVE',
  position: 0,
};

// O que cada assunto quer dizer, em português de quem atende. Sem isso a lista
// vira uma fileira de palavras em caixa alta que não explicam nada.
const EXPLICACAO_DO_TOPICO: Record<string, string> = {
  VOZ: 'Como ele fala: o jeito, o tamanho da frase, o cumprimento, o emoji.',
  PRECO: 'O que ele pode e não pode dizer sobre valor.',
  AVALIACAO: 'Como ele fala do teste de mecha e da avaliação.',
  AGENDAMENTO: 'Como ele oferece e fecha horário.',
  PROCEDIMENTO: 'O que o salão sabe sobre química, cabelo e técnica.',
  PROMOCAO: 'Como ele trata quem chegou por uma promoção.',
  FOTOS: 'O que ele faz com as fotos que a cliente manda.',
  ATENDIMENTO: 'Como ele recebe, acolhe e conduz a conversa.',
  OUTRO: 'O que não cabe nos outros assuntos.',
};

function quando(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function dia(iso: string | null): string {
  if (!iso) return '—';
  const [ano, mes, d] = iso.slice(0, 10).split('-');
  return `${d}/${mes}/${ano}`;
}

export default function TelaDoAgente() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [aba, setAba] = useState<Aba>('REGRAS');
  const [topicos, setTopicos] = useState<string[]>([]);
  const [politicas, setPoliticas] = useState<Politica[]>([]);
  const [artes, setArtes] = useState<Arte[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [rascunho, setRascunho] = useState<Rascunho | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [apagando, setApagando] = useState<string | null>(null);
  const [notas, setNotas] = useState<Record<string, string>>({});
  const [salvandoArte, setSalvandoArte] = useState<string | null>(null);
  const tenantRef = useRef<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    const pedido = new URLSearchParams(window.location.search).get('tenantId');
    fetch(`/api/dashboard-context${pedido ? `?tenantId=${encodeURIComponent(pedido)}` : ''}`, {
      signal: controller.signal,
    })
      .then(async (r) => {
        const body = await r.json();
        if (!r.ok) throw new Error(r.status === 401 ? 'AUTH' : (body.error ?? 'CONTEXTO'));
        return body;
      })
      .then((body) => {
        const w = body.activeWorkspace as Workspace;
        tenantRef.current = w.tenantId;
        setWorkspace(w);
      })
      .catch((e: unknown) => {
        if (e instanceof DOMException && e.name === 'AbortError') return;
        if (e instanceof Error && e.message === 'AUTH') {
          window.location.assign('/login');
          return;
        }
        setErro('Não foi possível resolver o negócio desta sessão.');
        setCarregando(false);
      });
    return () => controller.abort();
  }, []);

  const buscar = useCallback(async () => {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    try {
      const [rRegras, rArtes] = await Promise.all([
        fetch('/api/agente', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ action: 'loadAgentPolicies', tenantId }),
        }),
        fetch('/api/agente', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ action: 'loadStatusArts', tenantId }),
        }),
      ]);

      const corpoRegras = await rRegras.json();
      if (!rRegras.ok) throw new Error(corpoRegras.error ?? 'REGRAS_INDISPONIVEIS');
      const dados = corpoRegras.data as { topics?: string[]; policies?: Politica[] };
      setTopicos(dados.topics ?? []);
      setPoliticas(dados.policies ?? []);

      // Falha só nas artes não derruba as regras.
      if (rArtes.ok) {
        const corpoArtes = await rArtes.json();
        const lista = (corpoArtes.data ?? []) as Arte[];
        setArtes(lista);
        setNotas((atual) => {
          const proximo = { ...atual };
          for (const a of lista) if (!(a.id in proximo)) proximo[a.id] = a.ownerNote ?? '';
          return proximo;
        });
      }
      setErro(null);
    } catch {
      setErro('Não foi possível carregar as regras do agente.');
    } finally {
      setCarregando(false);
    }
  }, []);

  useEffect(() => {
    if (!workspace) return;
    void buscar();
  }, [workspace, buscar]);

  async function salvarRegra() {
    const tenantId = tenantRef.current;
    if (!tenantId || !rascunho) return;
    if (rascunho.title.trim().length < 2 || rascunho.body.trim().length < 2) {
      setAviso('A regra precisa de um título e de um texto.');
      return;
    }
    setSalvando(true);
    setAviso(null);
    try {
      const r = await fetch('/api/agente', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          action: 'saveAgentPolicy',
          tenantId,
          policy: {
            // Regra nova vai sem id: o banco decide se cria ou atualiza.
            ...(rascunho.id ? { id: rascunho.id } : {}),
            topic: rascunho.topic,
            title: rascunho.title.trim(),
            body: rascunho.body.trim(),
            status: rascunho.status,
            position: rascunho.position,
          },
        }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA_AO_SALVAR');
      // A RPC responde ok:false com um motivo em vez de erro HTTP.
      const resposta = body.data as { ok?: boolean; reason?: string };
      if (resposta?.ok === false) {
        setAviso(
          resposta.reason === 'TITLE_REQUIRED'
            ? 'A regra precisa de um título.'
            : resposta.reason === 'BODY_REQUIRED'
              ? 'A regra precisa de um texto.'
              : `Não foi possível salvar: ${resposta.reason ?? 'motivo desconhecido'}.`
        );
        return;
      }
      setRascunho(null);
      setAviso('Regra salva. Ela já vale na próxima mensagem que o agente responder.');
      await buscar();
    } catch {
      setAviso('Não foi possível salvar. Nada foi alterado.');
    } finally {
      setSalvando(false);
    }
  }

  async function apagarRegra(politica: Politica) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    if (
      !window.confirm(
        `Apagar a regra "${politica.title}"? O agente deixa de seguir isso na próxima mensagem.`
      )
    ) {
      return;
    }
    setApagando(politica.id);
    setAviso(null);
    try {
      const r = await fetch('/api/agente', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'deleteAgentPolicy', tenantId, policyId: politica.id }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA_AO_APAGAR');
      setAviso('Regra apagada.');
      await buscar();
    } catch {
      setAviso('Não foi possível apagar. Nada foi alterado.');
    } finally {
      setApagando(null);
    }
  }

  async function mexerNaArte(arte: Arte, mudanca: { ownerNote?: string; retired?: boolean }) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    setSalvandoArte(arte.id);
    setAviso(null);
    try {
      const r = await fetch('/api/agente', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'updateStatusArt', tenantId, artId: arte.id, ...mudanca }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA_NA_ARTE');
      setAviso(
        mudanca.retired === true
          ? 'Arte aposentada. O agente não usa mais o que estava nela.'
          : mudanca.retired === false
            ? 'Arte reativada.'
            : 'Observação salva.'
      );
      await buscar();
    } catch {
      setAviso('Não foi possível salvar. Nada foi alterado.');
    } finally {
      setSalvandoArte(null);
    }
  }

  // Agrupado por assunto, na ordem em que o banco devolve os tópicos: é a mesma
  // ordem em que as regras chegam ao agente.
  const porTopico = useMemo(() => {
    const mapa = new Map<string, Politica[]>();
    for (const p of politicas) {
      const lista = mapa.get(p.topic) ?? [];
      lista.push(p);
      mapa.set(p.topic, lista);
    }
    for (const lista of mapa.values()) lista.sort((a, b) => a.position - b.position);
    return mapa;
  }, [politicas]);

  const ativas = politicas.filter((p) => p.status === 'ACTIVE').length;
  const artesNoAr = artes.filter((a) => !a.retired).length;

  if (carregando) {
    return (
      <main className={styles.estado} aria-busy="true">
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>agente</span>
          <h1>Abrindo as regras.</h1>
          <p>Confirmando o negócio autorizado para esta sessão.</p>
        </section>
      </main>
    );
  }

  if (erro && politicas.length === 0) {
    return (
      <main className={styles.estado}>
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>agente</span>
          <h1>Regras indisponíveis.</h1>
          <p>{erro}</p>
        </section>
      </main>
    );
  }

  return (
    <main className={styles.shell}>
      <header className={styles.topo}>
        <div>
          <a className={styles.voltar} href="/dashboard">
            ← Voltar à operação
          </a>
          <span className={styles.eyebrow}>agente · {workspace?.tenantName ?? ''}</span>
          <h1>Como o agente atende</h1>
        </div>
      </header>

      {erro && <p className={styles.aviso}>{erro}</p>}

      <section className={styles.contadores}>
        {[
          ['regras valendo', ativas],
          ['assuntos com regra', porTopico.size],
          ['artes de status no ar', artesNoAr],
        ].map(([rotulo, valor]) => (
          <div key={String(rotulo)} className={styles.contador}>
            <strong>{String(valor)}</strong>
            <span>{rotulo}</span>
          </div>
        ))}
      </section>

      <nav className={styles.abas}>
        {(
          [
            ['REGRAS', 'Regras do salão'],
            ['ARTES', 'Artes de status'],
          ] as Array<[Aba, string]>
        ).map(([chave, rotulo]) => (
          <button
            key={chave}
            className={`${styles.aba} ${aba === chave ? styles.abaAtiva : ''}`}
            aria-pressed={aba === chave}
            onClick={() => setAba(chave)}
          >
            {rotulo}
          </button>
        ))}
      </nav>

      {aviso && <p className={styles.recado}>{aviso}</p>}

      {aba === 'REGRAS' && (
        <section className={styles.corpo}>
          <p className={styles.explicacao}>
            Isto é o que você manda o agente fazer, escrito do seu jeito. Ele lê todas as regras
            antes de responder qualquer cliente, e o que estiver aqui vale mais que o comportamento
            padrão dele. Escreva como você falaria com uma pessoa nova na recepção.
          </p>

          {!rascunho && (
            <button
              className={styles.principal}
              onClick={() => {
                setRascunho({ ...RASCUNHO_VAZIO });
                setAviso(null);
              }}
            >
              Escrever uma regra nova
            </button>
          )}

          {rascunho && (
            <article className={styles.editor}>
              <header className={styles.editorTopo}>
                <h2>{rascunho.id ? 'Editando a regra' : 'Regra nova'}</h2>
                <button className={styles.ghost} onClick={() => setRascunho(null)}>
                  Cancelar
                </button>
              </header>

              <div className={styles.grade}>
                <label>
                  Assunto
                  <select
                    value={rascunho.topic}
                    onChange={(e) => setRascunho({ ...rascunho, topic: e.target.value })}
                  >
                    {(topicos.length > 0 ? topicos : ['VOZ']).map((t) => (
                      <option key={t} value={t}>
                        {t}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  Ordem dentro do assunto
                  <input
                    type="number"
                    value={rascunho.position}
                    onChange={(e) =>
                      setRascunho({ ...rascunho, position: Number(e.target.value) || 0 })
                    }
                  />
                </label>
                <label>
                  Valendo?
                  <select
                    value={rascunho.status}
                    onChange={(e) => setRascunho({ ...rascunho, status: e.target.value })}
                  >
                    <option value="ACTIVE">sim, o agente segue</option>
                    <option value="DRAFT">rascunho, ele ignora</option>
                    <option value="ARCHIVED">arquivada</option>
                  </select>
                </label>
              </div>

              <p className={styles.dica}>{EXPLICACAO_DO_TOPICO[rascunho.topic] ?? ''}</p>

              <label className={styles.campoLargo}>
                Título
                <input
                  value={rascunho.title}
                  maxLength={120}
                  placeholder="Em poucas palavras, do que é esta regra"
                  onChange={(e) => setRascunho({ ...rascunho, title: e.target.value })}
                />
              </label>

              <label className={styles.campoLargo}>
                A regra
                <textarea
                  rows={7}
                  maxLength={2000}
                  value={rascunho.body}
                  placeholder="Escreva como você explicaria para uma pessoa nova no salão. Diga o que fazer e, quando importar, o que NÃO fazer."
                  onChange={(e) => setRascunho({ ...rascunho, body: e.target.value })}
                />
                <em className={styles.contagem}>{rascunho.body.length}/2000</em>
              </label>

              <div className={styles.editorAcoes}>
                <button
                  className={styles.principal}
                  disabled={salvando}
                  onClick={() => void salvarRegra()}
                >
                  {salvando ? 'Salvando…' : 'Salvar regra'}
                </button>
              </div>
            </article>
          )}

          {politicas.length === 0 && (
            <p className={styles.vazio}>
              Nenhuma regra escrita ainda. Sem regra, o agente atende do jeito padrão.
            </p>
          )}

          {[...porTopico.entries()].map(([topico, lista]) => (
            <section key={topico} className={styles.grupo}>
              <header className={styles.grupoTopo}>
                <h2>{topico}</h2>
                <span>{EXPLICACAO_DO_TOPICO[topico] ?? ''}</span>
              </header>
              {lista.map((p) => (
                <article
                  key={p.id}
                  className={`${styles.regra} ${p.status !== 'ACTIVE' ? styles.regraInativa : ''}`}
                >
                  <div className={styles.regraTopo}>
                    <strong>{p.title}</strong>
                    <div className={styles.regraAcoes}>
                      {p.status !== 'ACTIVE' && (
                        <span className={styles.selo}>
                          {p.status === 'DRAFT' ? 'rascunho' : 'arquivada'}
                        </span>
                      )}
                      <button
                        className={styles.ghost}
                        onClick={() => {
                          setRascunho({
                            id: p.id,
                            topic: p.topic,
                            title: p.title,
                            body: p.body,
                            status: p.status,
                            position: p.position,
                          });
                          setAviso(null);
                          window.scrollTo({ top: 0, behavior: 'smooth' });
                        }}
                      >
                        Editar
                      </button>
                      <button
                        className={styles.ghostPerigo}
                        disabled={apagando === p.id}
                        onClick={() => void apagarRegra(p)}
                      >
                        {apagando === p.id ? 'Apagando…' : 'Apagar'}
                      </button>
                    </div>
                  </div>
                  <p className={styles.regraTexto}>{p.body}</p>
                  <span className={styles.regraRodape}>
                    ordem {p.position} · alterada em {quando(p.updatedAt)}
                  </span>
                </article>
              ))}
            </section>
          ))}
        </section>
      )}

      {aba === 'ARTES' && (
        <section className={styles.corpo}>
          <p className={styles.explicacao}>
            Quando uma cliente responde um status do salão, o agente lê a arte e guarda o que
            entendeu dela. É daí que ele tira o valor e o que está incluso. Você não edita o que ele
            leu — isso é o que ele viu. Se estiver errado ou incompleto, escreva a correção na
            observação: ela vale mais que a leitura. Quando a promoção acabar, aposente a arte.
          </p>

          {artes.length === 0 && (
            <p className={styles.vazio}>
              Nenhuma arte de status lida ainda. Elas aparecem quando uma cliente responde um status
              do salão.
            </p>
          )}

          {artes.map((a) => (
            <article
              key={a.id}
              className={`${styles.arte} ${a.retired ? styles.arteAposentada : ''}`}
            >
              <div className={styles.arteTopo}>
                <div>
                  <span className={styles.eyebrow}>
                    {a.retired ? 'aposentada' : 'no ar'} · vista {a.timesSeen ?? 0}{' '}
                    {(a.timesSeen ?? 0) === 1 ? 'vez' : 'vezes'}
                  </span>
                  <span className={styles.arteDatas}>
                    primeira vez em {dia(a.firstSeenOn)} · última em {quando(a.lastSeenAt)}
                  </span>
                </div>
                <button
                  className={a.retired ? styles.ghost : styles.ghostPerigo}
                  disabled={salvandoArte === a.id}
                  onClick={() => void mexerNaArte(a, { retired: !a.retired })}
                >
                  {salvandoArte === a.id
                    ? 'Salvando…'
                    : a.retired
                      ? 'Reativar'
                      : 'Aposentar esta arte'}
                </button>
              </div>

              <pre className={styles.leitura}>{a.understanding ?? 'Sem leitura registrada.'}</pre>

              <label className={styles.campoLargo}>
                Sua observação sobre esta arte
                <textarea
                  rows={3}
                  value={notas[a.id] ?? ''}
                  placeholder="Corrija ou complete o que ele leu. Ex.: o valor subiu para R$ 480, o combo não inclui mais o corte."
                  onChange={(e) => setNotas({ ...notas, [a.id]: e.target.value })}
                />
              </label>
              <div className={styles.editorAcoes}>
                <button
                  className={styles.principal}
                  disabled={salvandoArte === a.id || (notas[a.id] ?? '') === (a.ownerNote ?? '')}
                  onClick={() => void mexerNaArte(a, { ownerNote: notas[a.id] ?? '' })}
                >
                  {salvandoArte === a.id ? 'Salvando…' : 'Salvar observação'}
                </button>
              </div>
            </article>
          ))}
        </section>
      )}
    </main>
  );
}
