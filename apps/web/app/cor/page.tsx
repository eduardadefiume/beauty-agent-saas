'use client';

// Tela de Cor.
//
// O QUE ELA RESOLVE. A dona perguntou: "como o agente vai saber que tal tom se
// encaixa em iluminado, qual tom se encaixa em ruivo, quais tons se encaixam
// em loiro, quais tons e em quais tons do cabelo da cliente precisa de pré
// pigmentação". Esta tela é onde essas respostas entram -- e a decisão de
// produto dela é o que ela NÃO pede.
//
// A FAMÍLIA SE DEFINE POR FOTO, NÃO POR NÚMERO. A primeira versão desta tela
// pedia "de qual altura de tom até qual vai o Ruivo?". Isso é pedir que um
// cabeleireiro traduza o ofício dele para uma escala numérica antes de poder
// responder. Ele não pensa assim: ele olha uma foto e sabe na hora se aquilo é
// ruivo ou é morena iluminada. Então o que ele faz aqui é subir foto e dizer a
// classe. A faixa de altura de tom continua existindo, porque a conta de
// clareamento precisa dela -- mas ela é LIDA das fotos, e aparece nesta tela
// como consequência, não como campo.
//
// Ela também não pede a tabela de decisão. Clarear quantos níveis exige
// descoloração, escurecer descolorido exige pré-pigmentação, clarear exige
// matização: isso é química, é igual em todo salão, e está no banco como conta.
//
// E ela mostra a diferença entre o que o dono respondeu e o que ainda é
// sugestão do sistema. Se tudo aparecesse preenchido igual, ele abriria a tela,
// veria tudo pronto e não responderia nada.

import Link from 'next/link';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import styles from './cor.module.css';

type Nivel = { level: number; name: string; underlyingPigment: string };

type FotoDeReferencia = {
  id: string;
  storagePath: string;
  caption: string | null;
  // Lida da foto pelo motor. Nula enquanto a leitura não rodou.
  estimatedLevel: number | null;
  levelSource: 'LIDO_NA_FOTO' | 'PESSOA' | null;
  readAt: string | null;
  readError: string | null;
};

type Familia = {
  id: string;
  name: string;
  description: string | null;
  needsWarmBase: boolean;
  extraMinutes: number | null;
  extraPriceMinor: number | null;
  // Consequência das fotos, não campo: `rangeFromPhotos` diz se já veio delas.
  rangeMin: number | null;
  rangeMax: number | null;
  rangeFromPhotos: boolean;
  photos: FotoDeReferencia[];
};

type Pergunta = {
  id: string;
  key: string;
  question: string;
  helper: string | null;
  unit: 'NIVEIS' | 'MINUTOS' | 'REAIS' | 'SIM_NAO';
  suggestedValue: number;
  answerValue: number | null;
  answered: boolean;
  answeredAt: string | null;
};

type Modelo = { levels: Nivel[]; families: Familia[]; questions: Pergunta[] };
type Workspace = { tenantId: string; tenantName: string; timezone: string };

// O componente de fotos precisa do tenant que a tela resolveu. Um módulo-nível
// simples resolve sem espalhar props por três camadas -- e ele é sempre escrito
// antes de qualquer foto poder ser subida.
let tenantGlobal: string | null = null;

const UNIDADE: Record<Pergunta['unit'], string> = {
  NIVEIS: 'níveis',
  MINUTOS: 'minutos',
  REAIS: 'reais',
  SIM_NAO: '',
};

// As fotos de uma família: subir, ver, corrigir a altura lida e remover.
//
// O balde é privado, então cada foto precisa de uma URL assinada para aparecer.
// Assinar sob demanda, e não guardar a URL, é o que faz o link expirar sozinho
// em dez minutos em vez de vazar num histórico de navegador.
function FotosDaFamilia({
  familia,
  niveis,
  onMudou,
  aoFalhar,
}: {
  familia: Familia;
  niveis: Nivel[];
  onMudou: () => void;
  aoFalhar: (mensagem: string) => void;
}) {
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [subindo, setSubindo] = useState(false);

  useEffect(() => {
    let vivo = true;
    void (async () => {
      const novas: Record<string, string> = {};
      for (const foto of familia.photos) {
        try {
          const r = await fetch(`/api/cor/foto?path=${encodeURIComponent(foto.storagePath)}`);
          const body = await r.json();
          if (r.ok && body.data?.url) novas[foto.id] = body.data.url as string;
        } catch {
          /* foto que não abre aparece como moldura vazia, não derruba a tela */
        }
      }
      if (vivo) setUrls(novas);
    })();
    return () => {
      vivo = false;
    };
  }, [familia.photos]);

  async function subir(arquivos: FileList | null) {
    if (!arquivos || arquivos.length === 0) return;
    const tenantId = new URLSearchParams(window.location.search).get('tenantId') ?? tenantGlobal;
    if (!tenantId) return;
    setSubindo(true);
    try {
      for (const arquivo of Array.from(arquivos)) {
        const formulario = new FormData();
        formulario.append('tenantId', tenantId);
        formulario.append('file', arquivo);
        const envio = await fetch('/api/cor/foto', { method: 'POST', body: formulario });
        const corpoEnvio = await envio.json();
        if (!envio.ok) throw new Error(corpoEnvio.error ?? 'UPLOAD_FALHOU');

        const registro = await fetch('/api/cor', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            action: 'addTonePhoto',
            tenantId,
            familyId: familia.id,
            storagePath: corpoEnvio.data.storagePath,
          }),
        });
        if (!registro.ok) {
          const corpo = await registro.json();
          throw new Error(corpo.error ?? 'REGISTRO_FALHOU');
        }
      }
      onMudou();
    } catch {
      aoFalhar('Não foi possível subir a foto. Tente de novo.');
    } finally {
      setSubindo(false);
    }
  }

  async function mexerNaFoto(photoId: string, corpo: Record<string, unknown>) {
    const tenantId = new URLSearchParams(window.location.search).get('tenantId') ?? tenantGlobal;
    if (!tenantId) return;
    try {
      const r = await fetch('/api/cor', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'updateTonePhoto', tenantId, photoId, ...corpo }),
      });
      if (!r.ok) throw new Error('FALHOU');
      onMudou();
    } catch {
      aoFalhar('Não foi possível alterar esta foto.');
    }
  }

  return (
    <div className={styles.fotos}>
      {familia.photos.length === 0 && (
        <p className={styles.nota}>
          Sem foto, o sistema não sabe o que este salão chama de {familia.name.toLowerCase()}.
        </p>
      )}

      <div className={styles.tiras}>
        {familia.photos.map((foto) => (
          <figure key={foto.id} className={styles.tira}>
            {urls[foto.id] ? (
              // <img> e não next/image de propósito: a URL é assinada e expira
              // em dez minutos, e o otimizador do Next guardaria em cache uma
              // imagem cujo link já morreu.
              <img src={urls[foto.id]} alt={foto.caption ?? 'Foto de referência'} />
            ) : (
              <div className={styles.tiraVazia} />
            )}
            <figcaption>
              <select
                value={foto.estimatedLevel ?? ''}
                onChange={(e) =>
                  void mexerNaFoto(foto.id, {
                    level: e.target.value ? Number(e.target.value) : null,
                  })
                }
              >
                <option value="">{foto.readError ? 'não deu para ler' : 'lendo…'}</option>
                {niveis.map((n) => (
                  <option key={n.level} value={n.level}>
                    altura {n.level}
                  </option>
                ))}
              </select>
              <span className={foto.levelSource === 'PESSOA' ? styles.selo : styles.seloSugerido}>
                {foto.levelSource === 'PESSOA'
                  ? 'você corrigiu'
                  : foto.levelSource === 'LIDO_NA_FOTO'
                    ? 'lido na foto'
                    : 'ainda não lida'}
              </span>
              <button
                type="button"
                className={styles.remover}
                onClick={() => void mexerNaFoto(foto.id, { remove: true })}
              >
                remover
              </button>
            </figcaption>
          </figure>
        ))}
      </div>

      <label className={styles.subir}>
        {subindo ? 'subindo…' : `+ fotos de ${familia.name.toLowerCase()}`}
        <input
          type="file"
          accept="image/jpeg,image/png,image/webp"
          multiple
          disabled={subindo}
          onChange={(e) => void subir(e.target.files)}
        />
      </label>
    </div>
  );
}

export default function TelaDeCor() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [modelo, setModelo] = useState<Modelo | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [salvando, setSalvando] = useState(false);
  const [sujo, setSujo] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [recado, setRecado] = useState<string | null>(null);
  const tenantRef = useRef<string | null>(null);

  // Mesmo caminho das outras telas: o negócio da sessão vem do servidor, o
  // navegador não escolhe em nome de quem age.
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
        tenantGlobal = w.tenantId;
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
      const r = await fetch('/api/cor', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'loadColorModel', tenantId }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'MODELO_INDISPONIVEL');
      setModelo(body.data as Modelo);
      setErro(null);
    } catch {
      setErro('Falha ao carregar o modelo de cor.');
    } finally {
      setCarregando(false);
    }
  }, []);

  useEffect(() => {
    if (!workspace) return;
    void buscar();
  }, [workspace, buscar]);

  function editarFamilia(id: string, mudanca: Partial<Familia>) {
    setModelo((atual) =>
      atual
        ? {
            ...atual,
            families: atual.families.map((f) => (f.id === id ? { ...f, ...mudanca } : f)),
          }
        : atual
    );
    setSujo(true);
    setRecado(null);
  }

  function responder(key: string, valor: string) {
    const numero = valor.trim() === '' ? null : Number(valor);
    setModelo((atual) =>
      atual
        ? {
            ...atual,
            questions: atual.questions.map((p) =>
              p.key === key
                ? {
                    ...p,
                    answerValue: Number.isFinite(numero) ? numero : null,
                    answered: numero != null,
                  }
                : p
            ),
          }
        : atual
    );
    setSujo(true);
    setRecado(null);
  }

  async function salvar() {
    const tenantId = tenantRef.current;
    if (!tenantId || !modelo) return;
    setSalvando(true);
    try {
      const r = await fetch('/api/cor', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          action: 'saveColorModel',
          tenantId,
          payload: {
            // Faixa não vai: ela é lida das fotos, e mandá-la daqui reabriria
            // a porta que a correção fechou.
            families: modelo.families.map((f) => ({
              id: f.id,
              description: f.description ?? '',
              needsWarmBase: f.needsWarmBase,
              extraMinutes: f.extraMinutes ?? '',
              extraPriceMinor: f.extraPriceMinor ?? '',
            })),
            questions: modelo.questions.map((p) => ({
              key: p.key,
              answerValue: p.answerValue ?? '',
            })),
          },
        }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA_AO_SALVAR');
      setSujo(false);
      setRecado('Respostas gravadas. O agente já usa a partir da próxima mensagem.');
      await buscar();
    } catch {
      setErro('Não foi possível gravar. Nada foi perdido: tente de novo.');
    } finally {
      setSalvando(false);
    }
  }

  const respondidas = useMemo(
    () => (modelo?.questions ?? []).filter((p) => p.answered).length,
    [modelo]
  );
  // O que conta agora é quantas famílias já têm foto: é a foto que ensina.
  const familiasComFoto = useMemo(
    () => (modelo?.families ?? []).filter((f) => f.photos.length > 0).length,
    [modelo]
  );
  const fotosLidas = useMemo(
    () =>
      (modelo?.families ?? []).reduce(
        (total, f) => total + f.photos.filter((ph) => ph.estimatedLevel != null).length,
        0
      ),
    [modelo]
  );
  const fotosTotais = useMemo(
    () => (modelo?.families ?? []).reduce((total, f) => total + f.photos.length, 0),
    [modelo]
  );

  if (carregando) {
    return (
      <main className={styles.estado}>
        <div className={styles.estadoCard}>
          <span className={styles.eyebrow}>Cor</span>
          <h1>Abrindo o modelo de cor…</h1>
        </div>
      </main>
    );
  }

  if (erro && !modelo) {
    return (
      <main className={styles.estado}>
        <div className={styles.estadoCard}>
          <span className={styles.eyebrow}>Cor</span>
          <h1>Não deu para abrir</h1>
          <p>{erro}</p>
          <p>
            <Link href="/dashboard">Voltar ao painel</Link>
          </p>
        </div>
      </main>
    );
  }

  return (
    <main className={styles.shell}>
      <Link href="/dashboard" className={styles.voltar}>
        ← painel
      </Link>

      <header className={styles.topo}>
        <div>
          <span className={styles.eyebrow}>{workspace?.tenantName ?? 'Cor'}</span>
          <h1>Cor</h1>
        </div>
        <button
          type="button"
          className={`${styles.salvar} ${sujo ? styles.salvarPendente : ''}`}
          onClick={() => void salvar()}
          disabled={!sujo || salvando}
        >
          {salvando ? 'gravando…' : sujo ? 'Gravar respostas' : 'tudo gravado'}
        </button>
      </header>

      {erro && <p className={styles.aviso}>{erro}</p>}
      {recado && <p className={styles.recado}>{recado}</p>}

      <div className={styles.contadores}>
        <div className={styles.contador}>
          <strong>
            {familiasComFoto}/{modelo?.families.length ?? 0}
          </strong>
          <span>famílias com foto cadastrada</span>
        </div>
        <div className={styles.contador}>
          <strong>
            {fotosLidas}/{fotosTotais}
          </strong>
          <span>fotos com a altura de tom já lida</span>
        </div>
        <div className={styles.contador}>
          <strong>
            {respondidas}/{modelo?.questions.length ?? 0}
          </strong>
          <span>perguntas respondidas</span>
        </div>
      </div>

      <p className={styles.explicacao}>
        O que <strong>não</strong> está aqui é de propósito. Clarear além de certo ponto exige
        descoloração, escurecer cabelo descolorido exige pré-pigmentação, e todo clareamento deixa
        um fundo que precisa ser matizado — isso é química, vale em qualquer salão, e o sistema já
        sabe. Aqui só entram as respostas que mudam de salão para salão.
      </p>

      {/* --- A escala, só para leitura ------------------------------------ */}
      <section className={styles.bloco}>
        <span className={styles.blocoTitulo}>A escala de tom, e o fundo que aparece</span>
        <p className={styles.nota}>
          O <strong>fundo</strong> é o pigmento que aparece quando o fio é clareado até aquela
          altura. É contra ele que a matização trabalha, e é ele que explica por que um cabelo
          clareado até 7 fica alaranjado se ninguém matizar. Esta tabela é a mesma em todo lugar e
          não se edita.
        </p>
        <ol className={styles.escala}>
          {(modelo?.levels ?? []).map((n) => (
            <li key={n.level}>
              <strong>{n.level}</strong>
              <span className={styles.escalaNome}>{n.name}</span>
              <span className={styles.escalaFundo}>{n.underlyingPigment}</span>
            </li>
          ))}
        </ol>
      </section>

      {/* --- As famílias -------------------------------------------------- */}
      <section className={styles.bloco}>
        <span className={styles.blocoTitulo}>As famílias de tom deste salão</span>
        <p className={styles.nota}>
          Suba fotos e diga a que família cada uma pertence. É assim que o sistema aprende o que
          <strong> este</strong> salão chama de ruivo, de iluminado, de loiro — com as fotos de quem
          faz, não com uma lista pronta. A altura de tom de cada foto é lida automaticamente; a
          faixa da família sai daí, você não precisa digitar número nenhum.
        </p>

        {(modelo?.families ?? []).map((f) => (
          <article key={f.id} className={styles.familia}>
            <div className={styles.familiaTopo}>
              <div>
                <h2>{f.name}</h2>
                {f.description && <p className={styles.familiaDescricao}>{f.description}</p>}
              </div>
              <span className={f.rangeFromPhotos ? styles.selo : styles.seloSugerido}>
                {f.rangeFromPhotos
                  ? `altura ${f.rangeMin} a ${f.rangeMax}, pelas fotos`
                  : 'sem foto ainda'}
              </span>
            </div>

            <FotosDaFamilia
              familia={f}
              niveis={modelo?.levels ?? []}
              onMudou={() => void buscar()}
              aoFalhar={setErro}
            />

            <div className={styles.grade}>
              <label>
                Minutos a mais
                <input
                  type="number"
                  min={0}
                  value={f.extraMinutes ?? ''}
                  onChange={(e) =>
                    editarFamilia(f.id, {
                      extraMinutes: e.target.value ? Number(e.target.value) : null,
                    })
                  }
                  placeholder="0"
                />
              </label>
              <label>
                Reais a mais
                <input
                  type="number"
                  min={0}
                  value={f.extraPriceMinor == null ? '' : f.extraPriceMinor / 100}
                  onChange={(e) =>
                    editarFamilia(f.id, {
                      extraPriceMinor: e.target.value
                        ? Math.round(Number(e.target.value) * 100)
                        : null,
                    })
                  }
                  placeholder="0"
                />
              </label>
            </div>

            <label className={styles.quente}>
              <input
                type="checkbox"
                checked={f.needsWarmBase}
                onChange={(e) => editarFamilia(f.id, { needsWarmBase: e.target.checked })}
              />
              Esta família vive do fundo quente
              <span className={styles.quenteAjuda}>
                Marque em ruivo e acobreado: neles o fundo alaranjado sustenta a cor, e matizar
                seria tirar justamente o que ia segurar o tom.
              </span>
            </label>
          </article>
        ))}
      </section>

      {/* --- As perguntas ------------------------------------------------- */}
      <section className={styles.bloco}>
        <span className={styles.blocoTitulo}>O que só você sabe responder</span>
        <p className={styles.nota}>
          Enquanto você não responde, o sistema usa a sugestão ao lado — e avisa em toda conta que
          aquele número ainda é dele, não seu.
        </p>

        {(modelo?.questions ?? []).map((p) => (
          <article key={p.key} className={styles.pergunta}>
            <div className={styles.perguntaTexto}>
              <h3>{p.question}</h3>
              {p.helper && <p className={styles.nota}>{p.helper}</p>}
            </div>
            <div className={styles.perguntaResposta}>
              {p.unit === 'SIM_NAO' ? (
                <select
                  value={p.answerValue == null ? '' : String(p.answerValue)}
                  onChange={(e) => responder(p.key, e.target.value)}
                >
                  <option value="">
                    usar a sugestão ({p.suggestedValue === 1 ? 'sim' : 'não'})
                  </option>
                  <option value="1">sim</option>
                  <option value="0">não</option>
                </select>
              ) : (
                <input
                  type="number"
                  min={0}
                  value={p.answerValue ?? ''}
                  onChange={(e) => responder(p.key, e.target.value)}
                  placeholder={`sugestão: ${p.suggestedValue}`}
                />
              )}
              <span className={styles.unidade}>{UNIDADE[p.unit]}</span>
              <span className={p.answered ? styles.selo : styles.seloSugerido}>
                {p.answered ? 'sua resposta' : 'sugestão do sistema'}
              </span>
            </div>
          </article>
        ))}
      </section>

      <footer className={styles.rodape}>
        <p className={styles.nota}>
          Nada aqui promete tom para a cliente. O que o salão diz continua sendo o que já estava
          escrito nas regras do agente: quem determina até onde o fio chega é o teste de mecha. Este
          modelo serve para o agente saber o <strong>caminho</strong> — quantas etapas, quanto tempo
          a mais, quanto a mais, e quando o teste é obrigatório.
        </p>
      </footer>
    </main>
  );
}
