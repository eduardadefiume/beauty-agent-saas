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
// FOTOS. Cada resposta pode ter fotos de referência, e agora dá para subir por
// aqui. Elas existem porque descrever cabelo em texto funciona mal: "ocupa mais
// que a largura dos ombros" quer dizer coisas diferentes para pessoas
// diferentes, e uma foto resolve a ambiguidade que três linhas de texto não
// resolvem. A foto é o que o dono usa para ensinar, e é contra ela que o motor
// compara a foto que a cliente manda.

import { useCallback, useEffect, useRef, useState } from 'react';
import styles from './conhecimento.module.css';

type Foto = { id: string; storagePath: string; caption: string | null };

// De onde veio a linha. PRODUTO é palpite do sistema, não resposta do dono:
// é a diferença entre um cadastro preenchido e um cadastro respondido.
type Procedencia = 'PRODUTO' | 'PRODUTO_AJUSTADO' | 'SALAO';

type Opcao = {
  id: string;
  label: string;
  description: string | null;
  origin?: Procedencia;
  productCode?: string | null;
  photos: Foto[];
};

type Dimensao = {
  id: string;
  name: string;
  whatToLookAt: string | null;
  origin?: Procedencia;
  productCode?: string | null;
  options: Opcao[];
};

// O que o produto tem e este salão ainda não pegou.
type Sugestao = {
  code: string;
  name: string;
  whatToLookAt: string | null;
  options: { code: string; label: string; description: string | null }[];
};

// As regras da profissão. Não têm dono: valem igual em qualquer salão, e por
// isso aparecem aqui só para leitura.
type Regra = { code: string; subject: string; title: string; statement: string };

type Workspace = { tenantId: string; tenantName: string; timezone: string };

// Id temporário para linha nova. O banco só aceita uuid, então uma linha ainda
// não salva vai SEM id no payload e o banco gera o dele.
function idNovo(): string {
  return `novo:${Math.random().toString(36).slice(2)}`;
}
const ehNovo = (id: string) => id.startsWith('novo:');

// O selo é curto de propósito: ele fica ao lado do campo o tempo todo, e um
// selo comprido vira ruído em vez de informação.
function Selo({ origin }: { origin?: Procedencia | undefined }) {
  if (origin === 'PRODUTO') {
    return (
      <span className={styles.seloProduto} title="Veio do padrão do sistema e ninguém confirmou.">
        do padrão
      </span>
    );
  }
  if (origin === 'PRODUTO_AJUSTADO') {
    return (
      <span className={styles.seloAjustado} title="Veio do padrão e você reescreveu.">
        você ajustou
      </span>
    );
  }
  return null;
}

// As fotos de uma resposta: subir, ver, legendar e remover.
//
// Subir grava o arquivo no balde na hora, mas a LIGAÇÃO entre a foto e a
// resposta só existe depois de Gravar -- porque `site_save_knowledge`
// substitui a árvore inteira, e é ela quem decide o que fica. Por isso a foto
// entra no estado da tela e o aviso lembra de gravar: sem isso, o arquivo
// ficaria no balde sem ninguém apontando para ele.
function FotosDaOpcao({
  fotos,
  rotulo,
  tenantId,
  onMudou,
  aoFalhar,
}: {
  fotos: Foto[];
  rotulo: string;
  tenantId: string | null;
  onMudou: (fotos: Foto[]) => void;
  aoFalhar: (mensagem: string) => void;
}) {
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [subindo, setSubindo] = useState(false);

  useEffect(() => {
    let vivo = true;
    void (async () => {
      const novas: Record<string, string> = {};
      for (const foto of fotos) {
        try {
          const r = await fetch(
            `/api/conhecimento/foto?path=${encodeURIComponent(foto.storagePath)}`
          );
          const body = await r.json();
          if (r.ok && body.data?.url) novas[foto.id] = body.data.url as string;
        } catch {
          /* foto que não abre vira moldura vazia, não derruba a tela */
        }
      }
      if (vivo) setUrls(novas);
    })();
    return () => {
      vivo = false;
    };
  }, [fotos]);

  async function subir(arquivos: FileList | null) {
    if (!arquivos || arquivos.length === 0 || !tenantId) return;
    setSubindo(true);
    try {
      const novas: Foto[] = [];
      for (const arquivo of Array.from(arquivos)) {
        const formulario = new FormData();
        formulario.append('tenantId', tenantId);
        formulario.append('file', arquivo);
        const r = await fetch('/api/conhecimento/foto', { method: 'POST', body: formulario });
        const body = await r.json();
        if (!r.ok) throw new Error(body.error ?? 'UPLOAD_FALHOU');
        novas.push({ id: idNovo(), storagePath: body.data.storagePath as string, caption: null });
      }
      onMudou([...fotos, ...novas]);
      aoFalhar('Foto subida. Ela só fica ligada a esta resposta depois de você gravar.');
    } catch {
      aoFalhar('Não foi possível subir a foto. Aceita JPG, PNG e WEBP até 8 MB.');
    } finally {
      setSubindo(false);
    }
  }

  return (
    <div className={styles.fotos}>
      {fotos.length > 0 && (
        <div className={styles.tiras}>
          {fotos.map((f, iFoto) => (
            <figure key={f.id} className={styles.tira}>
              {urls[f.id] ? (
                // <img> e não next/image de propósito: a URL é assinada e
                // expira em dez minutos, e o otimizador guardaria em cache uma
                // imagem cujo link já morreu.
                <img src={urls[f.id]} alt={f.caption ?? `Referência de ${rotulo}`} />
              ) : (
                <div className={styles.tiraVazia} />
              )}
              <figcaption>
                <input
                  value={f.caption ?? ''}
                  placeholder="legenda"
                  onChange={(e) =>
                    onMudou(
                      fotos.map((ff, j) => (j === iFoto ? { ...ff, caption: e.target.value } : ff))
                    )
                  }
                />
                <button
                  type="button"
                  className={styles.ghostPerigo}
                  onClick={() => onMudou(fotos.filter((_, j) => j !== iFoto))}
                >
                  Remover
                </button>
              </figcaption>
            </figure>
          ))}
        </div>
      )}

      <label className={styles.subir}>
        {subindo
          ? 'subindo…'
          : `+ foto de referência${rotulo ? ` de ${rotulo.toLowerCase()}` : ''}`}
        <input
          type="file"
          accept="image/jpeg,image/png,image/webp"
          multiple
          disabled={subindo || !tenantId}
          onChange={(e) => void subir(e.target.files)}
        />
      </label>
    </div>
  );
}

export default function TelaDeConhecimento() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [dimensoes, setDimensoes] = useState<Dimensao[]>([]);
  const [sugestoes, setSugestoes] = useState<Sugestao[]>([]);
  const [regras, setRegras] = useState<Regra[]>([]);
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
      const dados = body.data as {
        dimensions?: Dimensao[];
        suggestions?: Sugestao[];
        rules?: Regra[];
      };
      setDimensoes(dados.dimensions ?? []);
      setSugestoes(dados.suggestions ?? []);
      setRegras(dados.rules ?? []);
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

  // Adotar uma sugestão traz as palavras do produto para dentro do salão. Ela
  // entra como linha nova, marcada como padrão, e some da lista de ofertas na
  // hora -- mas só existe de verdade depois de Gravar, como tudo aqui.
  function adotar(sugestao: Sugestao) {
    mexer([
      ...dimensoes,
      {
        id: idNovo(),
        name: sugestao.name,
        whatToLookAt: sugestao.whatToLookAt,
        origin: 'PRODUTO',
        productCode: sugestao.code,
        options: sugestao.options.map((o) => ({
          id: idNovo(),
          label: o.label,
          description: o.description,
          origin: 'PRODUTO',
          productCode: o.code,
          photos: [],
        })),
      },
    ]);
    setSugestoes(sugestoes.filter((s) => s.code !== sugestao.code));
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
              // O código do produto viaja junto: é ele que faz a linha nascer
              // marcada como padrão em vez de como resposta do dono.
              productCode: d.productCode ?? '',
              options: d.options.map((o) => ({
                ...(ehNovo(o.id) ? {} : { id: o.id }),
                label: o.label.trim(),
                description: o.description ?? '',
                productCode: o.productCode ?? '',
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
              <span className={styles.rotuloComSelo}>
                Pergunta <Selo origin={d.origin} />
              </span>
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
                    <span className={styles.rotuloComSelo}>
                      Resposta <Selo origin={o.origin} />
                    </span>
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

                <FotosDaOpcao
                  fotos={o.photos}
                  rotulo={o.label}
                  tenantId={workspace?.tenantId ?? null}
                  onMudou={(fotos) => editarOpcao(iDim, iOpt, { photos: fotos })}
                  aoFalhar={setAviso}
                />
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
                            {
                              id: idNovo(),
                              label: '',
                              description: '',
                              origin: 'SALAO',
                              photos: [],
                            },
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

      {sugestoes.length > 0 && (
        <section className={styles.oferta}>
          <h2>O padrão do sistema tem mais estas</h2>
          <p className={styles.nota}>
            São perguntas que a maioria dos salões usa. Não entram sozinhas: quem decide o que este
            salão observa é você. Ao adotar, as palavras vêm prontas e você reescreve o que quiser.
          </p>
          {sugestoes.map((sg) => (
            <div key={sg.code} className={styles.ofertaItem}>
              <div>
                <strong>{sg.name}</strong>
                <span>{sg.options.map((o) => o.label).join(' · ')}</span>
              </div>
              <button className={styles.ghost} onClick={() => adotar(sg)}>
                Adotar
              </button>
            </div>
          ))}
        </section>
      )}

      {regras.length > 0 && (
        <section className={styles.regras}>
          <h2>O que o sistema já sabe sobre cabelo</h2>
          <p className={styles.nota}>
            Estas regras valem em qualquer salão, então não são campo: elas não têm dono. É delas
            que sai a explicação quando o plano de cor diz que um caso precisa de descoloração ou de
            teste de mecha. Se você discorda de alguma, fale com a gente — mudar aqui mudaria para
            todos os salões.
          </p>
          {regras.map((r) => (
            <details key={r.code} className={styles.regra}>
              <summary>
                <strong>{r.title}</strong>
                <span className={styles.regraAssunto}>{r.subject.toLowerCase()}</span>
              </summary>
              <p>{r.statement}</p>
            </details>
          ))}
        </section>
      )}

      <div className={styles.rodape}>
        <button
          className={styles.principal}
          onClick={() =>
            mexer([
              ...dimensoes,
              { id: idNovo(), name: '', whatToLookAt: '', origin: 'SALAO', options: [] },
            ])
          }
        >
          Adicionar pergunta
        </button>
        <p className={styles.nota}>
          As fotos são privadas: só quem tem sessão no configurador vê, por link que expira em dez
          minutos.
        </p>
      </div>
    </main>
  );
}
