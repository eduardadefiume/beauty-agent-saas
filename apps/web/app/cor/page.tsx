'use client';

// Tela de Cor.
//
// O QUE ELA RESOLVE. A dona perguntou: "como o agente vai saber que tal tom se
// encaixa em iluminado, qual tom se encaixa em ruivo, quais tons se encaixam
// em loiro, quais tons e em quais tons do cabelo da cliente precisa de pré
// pigmentação". Esta tela é onde essas respostas entram -- e a decisão de
// produto dela é o que ela NÃO pede.
//
// Ela não pede a tabela de decisão. Clarear quantos níveis exige descoloração,
// escurecer descolorido exige pré-pigmentação, clarear exige matização: isso é
// química, é igual em todo salão, e está no banco como conta. Aqui só entram
// as poucas coisas que mudam de salão para salão -- as faixas de tom e os
// números de tempo e preço.
//
// E ela mostra a diferença entre o que o dono respondeu e o que ainda é
// sugestão do sistema. Se tudo aparecesse preenchido igual, ele abriria a tela,
// veria tudo pronto e não responderia nada.

import Link from 'next/link';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import styles from './cor.module.css';

type Nivel = { level: number; name: string; underlyingPigment: string };

type Familia = {
  id: string;
  name: string;
  description: string | null;
  minLevel: number | null;
  maxLevel: number | null;
  needsWarmBase: boolean;
  extraMinutes: number | null;
  extraPriceMinor: number | null;
  answered: boolean;
  answeredAt: string | null;
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

const UNIDADE: Record<Pergunta['unit'], string> = {
  NIVEIS: 'níveis',
  MINUTOS: 'minutos',
  REAIS: 'reais',
  SIM_NAO: '',
};

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
            families: modelo.families.map((f) => ({
              id: f.id,
              description: f.description ?? '',
              minLevel: f.minLevel ?? '',
              maxLevel: f.maxLevel ?? '',
              needsWarmBase: f.needsWarmBase,
              extraMinutes: f.extraMinutes ?? '',
              extraPriceMinor: f.extraPriceMinor ?? '',
              answered: f.answered,
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
  const familiasConfirmadas = useMemo(
    () => (modelo?.families ?? []).filter((f) => f.answered).length,
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
            {familiasConfirmadas}/{modelo?.families.length ?? 0}
          </strong>
          <span>famílias de tom confirmadas</span>
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
          Cada família cobre uma faixa da escala. É isso que responde “esse tom é loiro ou é
          iluminado?”. As faixas abaixo são uma sugestão do sistema — corrija e marque
          <em> confirmada</em> quando estiver do jeito daqui.
        </p>

        {(modelo?.families ?? []).map((f) => (
          <article key={f.id} className={styles.familia}>
            <div className={styles.familiaTopo}>
              <div>
                <h2>{f.name}</h2>
                {f.description && <p className={styles.familiaDescricao}>{f.description}</p>}
              </div>
              <label className={styles.confirmar}>
                <input
                  type="checkbox"
                  checked={f.answered}
                  onChange={(e) => editarFamilia(f.id, { answered: e.target.checked })}
                />
                {f.answered ? 'confirmada' : 'ainda é sugestão'}
              </label>
            </div>

            <div className={styles.grade}>
              <label>
                Da altura de tom
                <select
                  value={f.minLevel ?? ''}
                  onChange={(e) =>
                    editarFamilia(f.id, {
                      minLevel: e.target.value ? Number(e.target.value) : null,
                    })
                  }
                >
                  <option value="">—</option>
                  {(modelo?.levels ?? []).map((n) => (
                    <option key={n.level} value={n.level}>
                      {n.level} · {n.name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Até a altura de tom
                <select
                  value={f.maxLevel ?? ''}
                  onChange={(e) =>
                    editarFamilia(f.id, {
                      maxLevel: e.target.value ? Number(e.target.value) : null,
                    })
                  }
                >
                  <option value="">—</option>
                  {(modelo?.levels ?? []).map((n) => (
                    <option key={n.level} value={n.level}>
                      {n.level} · {n.name}
                    </option>
                  ))}
                </select>
              </label>
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
