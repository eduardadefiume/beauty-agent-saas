'use client';

// Tela de Conhecimento: o vocabulário com que o salão descreve um cabelo.
//
// O QUE ISTO É, NA PRÁTICA. Uma dimensão é uma pergunta que o salão faz sobre
// todo cabelo ("Comprimento"), e as opções são as respostas possíveis ("Curto",
// "Longo"). É esse vocabulário que aparece na ficha da cliente e é com ele que
// o agente anota o que descobriu.
//
// POR QUE ELA IMPORTA AGORA. A ficha da cliente tem um campo de volume que
// vive vazio, e não é bug: não existe nenhuma dimensão de volume cadastrada.
// Sem esta tela, criar uma era tarefa de quem tem acesso ao banco. O salão
// tinha duas palavras para descrever cabelo — Curto e Longo — e nenhuma forma
// de ganhar a terceira.
//
// CUIDADO AO SALVAR. `site_save_knowledge` SUBSTITUI a árvore inteira: o que
// não vier no corpo é apagado, inclusive as fotos de referência. Por isso a
// tela sempre manda tudo que carregou, e apagar aqui é apagar de verdade — daí
// a confirmação.
//
// FOTOS. As fotos de referência que já existem são preservadas e podem ser
// removidas, mas ainda NÃO dá para subir foto nova por esta tela: falta a rota
// de upload. Isso está dito na tela, em vez de um botão que não funciona.

import { useCallback, useEffect, useRef, useState } from 'react';
import styles from './conhecimento.module.css';

type Foto = { id: string; storagePath: string; caption: string | null };

type Opcao = {
  id: string;
  label: string;
  description: string | null;
  photos: Foto[];
};

type Dimensao = {
  id: string;
  name: string;
  whatToLookAt: string | null;
  options: Opcao[];
};

type Workspace = { tenantId: string; tenantName: string; timezone: string };

// Id temporário para linha nova. O banco só aceita uuid, então uma linha ainda
// não salva vai SEM id no payload e o banco gera o dele.
function idNovo(): string {
  return `novo:${Math.random().toString(36).slice(2)}`;
}
const ehNovo = (id: string) => id.startsWith('novo:');

export default function TelaDeConhecimento() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [dimensoes, setDimensoes] = useState<Dimensao[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [sujo, setSujo] = useState(false);
  const [salvando, setSalvando] = useState(false);
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
      const r = await fetch('/api/conhecimento', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'loadKnowledge', tenantId }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'CONHECIMENTO_INDISPONIVEL');
      const dados = body.data as { dimensions?: Dimensao[] };
      setDimensoes(dados.dimensions ?? []);
      setSujo(false);
      setErro(null);
    } catch {
      setErro('Não foi possível carregar o conhecimento do salão.');
    } finally {
      setCarregando(false);
    }
  }, []);

  useEffect(() => {
    if (!workspace) return;
    void buscar();
  }, [workspace, buscar]);

  function mexer(proximo: Dimensao[]) {
    setDimensoes(proximo);
    setSujo(true);
    setAviso(null);
  }

  function editarDimensao(indice: number, mudanca: Partial<Dimensao>) {
    mexer(dimensoes.map((d, i) => (i === indice ? { ...d, ...mudanca } : d)));
  }

  function editarOpcao(iDim: number, iOpt: number, mudanca: Partial<Opcao>) {
    mexer(
      dimensoes.map((d, i) =>
        i !== iDim
          ? d
          : { ...d, options: d.options.map((o, j) => (j === iOpt ? { ...o, ...mudanca } : o)) }
      )
    );
  }

  async function salvar() {
    const tenantId = tenantRef.current;
    if (!tenantId) return;

    // O banco recusa dimensão sem nome e opção sem rótulo. Melhor dizer aqui,
    // apontando onde está o problema, do que devolver um código de erro.
    for (const d of dimensoes) {
      if (d.name.trim().length === 0) {
        setAviso('Toda pergunta precisa de um nome. Preencha ou remova a que está em branco.');
        return;
      }
      for (const o of d.options) {
        if (o.label.trim().length === 0) {
          setAviso(`Em "${d.name}", uma resposta está sem nome. Preencha ou remova.`);
          return;
        }
      }
    }

    setSalvando(true);
    setAviso(null);
    try {
      const r = await fetch('/api/conhecimento', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          action: 'saveKnowledge',
          tenantId,
          payload: {
            dimensions: dimensoes.map((d) => ({
              ...(ehNovo(d.id) ? {} : { id: d.id }),
              name: d.name.trim(),
              whatToLookAt: d.whatToLookAt ?? '',
              options: d.options.map((o) => ({
                ...(ehNovo(o.id) ? {} : { id: o.id }),
                label: o.label.trim(),
                description: o.description ?? '',
                // As fotos vão de volta inteiras: o que não vier é apagado.
                photos: o.photos.map((f) => ({
                  id: f.id,
                  storagePath: f.storagePath,
                  caption: f.caption ?? '',
                })),
              })),
            })),
          },
        }),
      });
      const body = await r.json();
      if (!r.ok) {
        const motivo = String(body.error ?? '');
        throw new Error(
          motivo.includes('SITE_TENANT_NOT_ACCESSIBLE')
            ? 'Só o dono do negócio pode mudar o conhecimento.'
            : motivo || 'FALHA_AO_SALVAR'
        );
      }
      setAviso('Conhecimento salvo. A ficha da cliente já usa este vocabulário.');
      await buscar();
    } catch (e: unknown) {
      setAviso(e instanceof Error ? e.message : 'Não foi possível salvar. Nada foi alterado.');
    } finally {
      setSalvando(false);
    }
  }

  if (carregando) {
    return (
      <main className={styles.estado} aria-busy="true">
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>conhecimento</span>
          <h1>Abrindo o conhecimento.</h1>
          <p>Confirmando o negócio autorizado para esta sessão.</p>
        </section>
      </main>
    );
  }

  if (erro && dimensoes.length === 0) {
    return (
      <main className={styles.estado}>
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>conhecimento</span>
          <h1>Conhecimento indisponível.</h1>
          <p>{erro}</p>
        </section>
      </main>
    );
  }

  const totalOpcoes = dimensoes.reduce((soma, d) => soma + d.options.length, 0);
  const totalFotos = dimensoes.reduce(
    (soma, d) => soma + d.options.reduce((s, o) => s + o.photos.length, 0),
    0
  );

  return (
    <main className={styles.shell}>
      <header className={styles.topo}>
        <div>
          <a className={styles.voltar} href="/dashboard">
            ← Voltar à operação
          </a>
          <span className={styles.eyebrow}>conhecimento · {workspace?.tenantName ?? ''}</span>
          <h1>Como o salão descreve um cabelo</h1>
        </div>
        <button
          className={`${styles.salvar} ${sujo ? styles.salvarPendente : ''}`}
          disabled={salvando || !sujo}
          onClick={() => void salvar()}
        >
          {salvando ? 'Salvando…' : sujo ? 'Salvar' : 'Tudo salvo'}
        </button>
      </header>

      {erro && <p className={styles.aviso}>{erro}</p>}
      {aviso && <p className={styles.recado}>{aviso}</p>}

      <section className={styles.contadores}>
        {[
          ['perguntas', dimensoes.length],
          ['respostas possíveis', totalOpcoes],
          ['fotos de referência', totalFotos],
        ].map(([rotulo, valor]) => (
          <div key={String(rotulo)} className={styles.contador}>
            <strong>{String(valor)}</strong>
            <span>{rotulo}</span>
          </div>
        ))}
      </section>

      <p className={styles.explicacao}>
        Cada <strong>pergunta</strong> aqui é uma coisa que o salão sempre quer saber sobre um
        cabelo, e as <strong>respostas</strong> são as opções que existem. É este vocabulário que
        aparece na ficha da cliente e é com ele que o agente anota o que descobriu — se não existe
        uma pergunta sobre volume, ele não tem como anotar volume nenhum.
      </p>

      {dimensoes.length === 0 && (
        <p className={styles.vazio}>
          Nenhuma pergunta cadastrada. Sem isso, a ficha da cliente não tem como classificar o
          cabelo.
        </p>
      )}

      {dimensoes.map((d, iDim) => (
        <article key={d.id} className={styles.dimensao}>
          <header className={styles.dimensaoTopo}>
            <label className={styles.campoNome}>
              Pergunta
              <input
                value={d.name}
                placeholder="ex.: Volume"
                onChange={(e) => editarDimensao(iDim, { name: e.target.value })}
              />
            </label>
            <button
              className={styles.ghostPerigo}
              onClick={() => {
                if (
                  !window.confirm(
                    `Remover a pergunta "${d.name || 'sem nome'}" e todas as respostas dela? ` +
                      'Ao salvar, isso some da ficha das clientes.'
                  )
                ) {
                  return;
                }
                mexer(dimensoes.filter((_, i) => i !== iDim));
              }}
            >
              Remover pergunta
            </button>
          </header>

          <label className={styles.campoLargo}>
            O que olhar para responder
            <input
              value={d.whatToLookAt ?? ''}
              placeholder="ex.: Quanto o cabelo ocupa de largura quando está solto."
              onChange={(e) => editarDimensao(iDim, { whatToLookAt: e.target.value })}
            />
          </label>

          <div className={styles.opcoes}>
            <span className={styles.opcoesTitulo}>Respostas possíveis</span>

            {d.options.length === 0 && (
              <p className={styles.nota}>
                Nenhuma resposta ainda. Uma pergunta sem resposta não serve para classificar nada.
              </p>
            )}

            {d.options.map((o, iOpt) => (
              <div key={o.id} className={styles.opcao}>
                <div className={styles.opcaoGrade}>
                  <label>
                    Resposta
                    <input
                      value={o.label}
                      placeholder="ex.: Muito volumoso"
                      onChange={(e) => editarOpcao(iDim, iOpt, { label: e.target.value })}
                    />
                  </label>
                  <label>
                    Como reconhecer
                    <input
                      value={o.description ?? ''}
                      placeholder="ex.: Ocupa mais que a largura dos ombros."
                      onChange={(e) => editarOpcao(iDim, iOpt, { description: e.target.value })}
                    />
                  </label>
                  <button
                    className={styles.ghostPerigo}
                    onClick={() =>
                      mexer(
                        dimensoes.map((dd, i) =>
                          i !== iDim
                            ? dd
                            : { ...dd, options: dd.options.filter((_, j) => j !== iOpt) }
                        )
                      )
                    }
                  >
                    Remover
                  </button>
                </div>

                {o.photos.length > 0 && (
                  <div className={styles.fotos}>
                    {o.photos.map((f, iFoto) => (
                      <div key={f.id} className={styles.foto}>
                        <code>{f.storagePath}</code>
                        <input
                          value={f.caption ?? ''}
                          placeholder="legenda"
                          onChange={(e) =>
                            editarOpcao(iDim, iOpt, {
                              photos: o.photos.map((ff, j) =>
                                j === iFoto ? { ...ff, caption: e.target.value } : ff
                              ),
                            })
                          }
                        />
                        <button
                          className={styles.ghostPerigo}
                          onClick={() =>
                            editarOpcao(iDim, iOpt, {
                              photos: o.photos.filter((_, j) => j !== iFoto),
                            })
                          }
                        >
                          Remover foto
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ))}

            <button
              className={styles.ghost}
              onClick={() =>
                mexer(
                  dimensoes.map((dd, i) =>
                    i !== iDim
                      ? dd
                      : {
                          ...dd,
                          options: [
                            ...dd.options,
                            { id: idNovo(), label: '', description: '', photos: [] },
                          ],
                        }
                  )
                )
              }
            >
              Adicionar resposta
            </button>
          </div>
        </article>
      ))}

      <div className={styles.rodape}>
        <button
          className={styles.principal}
          onClick={() =>
            mexer([...dimensoes, { id: idNovo(), name: '', whatToLookAt: '', options: [] }])
          }
        >
          Adicionar pergunta
        </button>
        <p className={styles.nota}>
          Subir foto de referência nova ainda não é possível por aqui — falta a rota de upload. As
          fotos que já existem continuam valendo e podem ser removidas.
        </p>
      </div>
    </main>
  );
}
