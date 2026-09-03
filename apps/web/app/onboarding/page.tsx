'use client';

// Tela de Onboarding: o dono fala, a IA preenche o rascunho.
//
// O QUE ELA RESOLVE. O configurador tem treze módulos e o dono de salão não
// tem tarde livre para percorrer os treze. Aqui ele fala do jeito que fala --
// "escova sessenta, escova com prancha oitenta" -- ou manda a foto da tabela
// de preços, e o sistema traduz isso em linha de catálogo.
//
// A PAUTA NÃO É INVENTADA. Ela vem de `onboarding_pendencies`, que lê o banco
// e devolve o que de fato está vazio: serviço sem preço, pergunta de cor sem
// resposta, família sem foto, assunto comercial sem regra escrita. Se a lista
// estivesse errada, a conversa inteira viraria teatro.
//
// O QUE A IA PODE MEXER. Quatro destinos, e nada além deles. Preço vai para o
// RASCUNHO, que não vale para ninguém até a publicação -- é literalmente
// preencher o rascunho. Toda escrita guarda o valor anterior, e desfazer é um
// clique.
//
// O QUE ELA MARCA COMO INCERTO. Abaixo de 0,75 de confiança nada é gravado: a
// linha aparece como proposta, para o dono confirmar ou descartar. É o mesmo
// limite do motor que lê foto de cabelo, e pelo mesmo motivo.

import { useCallback, useEffect, useRef, useState } from 'react';
import styles from './onboarding.module.css';

type Pergunta = { chave: string; pergunta: string; contexto: string };
type Pendencia = { modulo: string; quantas: number; primeiras: Pergunta[] };
type Fala = {
  id: string;
  quem: 'DONO' | 'SISTEMA';
  texto: string | null;
  midia: 'AUDIO' | 'FOTO' | null;
  erroLeitura: string | null;
  quando: string;
};
type Resposta = {
  id: string;
  chave: string;
  modulo: string;
  entendido: string;
  valorTexto: string | null;
  valorNumero: number | null;
  confianca: number | null;
  status: 'APLICADO' | 'PROPOSTO' | 'RECUSADO' | 'DESFEITO';
  motivo: string | null;
  quando: string;
};
type Estado = {
  sessionId: string | null;
  pendencias: Pendencia[];
  conversa: Fala[];
  respostas: Resposta[];
};
type Workspace = { tenantId: string; tenantName: string; timezone: string };

const NOME_DO_MODULO: Record<string, string> = {
  SERVICOS: 'Preços dos serviços',
  COR: 'Modelo de cor',
  CONHECIMENTO: 'Vocabulário do salão',
  REGRAS: 'Regras que o agente segue',
};

function moeda(valor: number): string {
  return valor.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

export default function TelaDeOnboarding() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [estado, setEstado] = useState<Estado | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const [texto, setTexto] = useState('');
  const [falando, setFalando] = useState(false);
  const tenantRef = useRef<string | null>(null);
  const fimDaConversa = useRef<HTMLDivElement | null>(null);

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

  const chamar = useCallback(async (corpo: Record<string, unknown>) => {
    const tenantId = tenantRef.current;
    if (!tenantId) throw new Error('SEM_TENANT');
    const r = await fetch('/api/onboarding', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...corpo, tenantId }),
    });
    const body = await r.json();
    if (!r.ok) throw new Error(String(body.error ?? 'FALHA'));
    return body.data as Record<string, unknown>;
  }, []);

  const buscar = useCallback(async () => {
    try {
      const dados = (await chamar({ action: 'onboardingState' })) as unknown as Estado;
      setEstado(dados);
      setErro(null);
    } catch {
      setErro('Não foi possível carregar o que ainda falta responder.');
    } finally {
      setCarregando(false);
    }
  }, [chamar]);

  useEffect(() => {
    if (!workspace) return;
    void buscar();
  }, [workspace, buscar]);

  useEffect(() => {
    fimDaConversa.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, [estado?.conversa.length]);

  async function garantirSessao(): Promise<string> {
    if (estado?.sessionId) return estado.sessionId;
    const aberta = (await chamar({ action: 'onboardingOpen' })) as { sessionId?: string };
    if (!aberta?.sessionId) throw new Error('SESSAO_NAO_ABRIU');
    return aberta.sessionId;
  }

  async function falar(comMidia?: { midia: 'AUDIO' | 'FOTO'; storagePath: string }) {
    const dito = texto.trim();
    if (!dito && !comMidia) return;

    setFalando(true);
    setErro(null);
    try {
      const sessionId = await garantirSessao();
      await chamar({
        action: 'onboardingSay',
        sessionId,
        texto: dito || null,
        midia: comMidia?.midia ?? null,
        storagePath: comMidia?.storagePath ?? null,
      });
      setTexto('');
      await buscar();
    } catch (e: unknown) {
      setErro(
        e instanceof Error && e.message === 'ANTHROPIC_API_KEY_MISSING'
          ? 'A chave do modelo não está configurada no servidor.'
          : 'Não consegui processar o que você mandou. Tente de novo.'
      );
    } finally {
      setFalando(false);
    }
  }

  async function mandarArquivo(arquivo: File) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    setFalando(true);
    setErro(null);
    try {
      const formulario = new FormData();
      formulario.set('tenantId', tenantId);
      formulario.set('file', arquivo);
      const r = await fetch('/api/onboarding/midia', { method: 'POST', body: formulario });
      const body = await r.json();
      if (!r.ok) {
        throw new Error(
          body.error === 'UNSUPPORTED_MEDIA_TYPE'
            ? 'Esse tipo de arquivo não dá. Mande foto (jpg, png, webp) ou áudio.'
            : body.error === 'FILE_TOO_LARGE'
              ? 'Arquivo grande demais: o limite é 8 MB.'
              : 'Não consegui subir o arquivo.'
        );
      }
      const caminho = (body.data as { storagePath: string }).storagePath;
      setFalando(false);
      await falar({
        midia: arquivo.type.startsWith('audio/') ? 'AUDIO' : 'FOTO',
        storagePath: caminho,
      });
    } catch (e: unknown) {
      setErro(e instanceof Error ? e.message : 'Não consegui subir o arquivo.');
      setFalando(false);
    }
  }

  async function desfazer(answerId: string) {
    try {
      await chamar({ action: 'onboardingUndo', answerId });
      await buscar();
    } catch {
      setErro('Não consegui desfazer. Nada foi alterado.');
    }
  }

  if (carregando) {
    return (
      <main className={styles.estado} aria-busy="true">
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>onboarding</span>
          <h1>Vendo o que ainda falta.</h1>
        </section>
      </main>
    );
  }

  const totalAberto = (estado?.pendencias ?? []).reduce((s, p) => s + p.quantas, 0);
  const propostas = (estado?.respostas ?? []).filter((r) => r.status === 'PROPOSTO');
  const aplicadas = (estado?.respostas ?? []).filter((r) => r.status === 'APLICADO');
  const recusadas = (estado?.respostas ?? []).filter((r) => r.status === 'RECUSADO');
  const proxima = (estado?.pendencias ?? [])[0]?.primeiras[0] ?? null;

  return (
    <main className={styles.shell}>
      <header className={styles.topo}>
        <div>
          <a className={styles.voltar} href="/dashboard">
            ← Voltar à operação
          </a>
          <span className={styles.eyebrow}>onboarding · {workspace?.tenantName ?? ''}</span>
          <h1>Me conta como funciona, que eu preencho</h1>
        </div>
        {totalAberto > 0 && (
          <span className={styles.contadorGrande}>
            <strong>{totalAberto}</strong>
            <span>ainda em aberto</span>
          </span>
        )}
      </header>

      {erro && <p className={styles.aviso}>{erro}</p>}

      <p className={styles.explicacao}>
        Fale do jeito que você fala no salão, ou mande a foto da sua tabela de preços. Eu preencho o{' '}
        <strong>rascunho</strong> — nada disso chega na cliente antes de você publicar. O que eu não
        entender direito eu não gravo: deixo separado para você conferir.
      </p>

      {/* --- A pauta ------------------------------------------------------ */}
      <section className={styles.pauta}>
        {(estado?.pendencias ?? []).length === 0 ? (
          <p className={styles.tudoCerto}>
            Não achei nada em aberto. Preço, cor, vocabulário e regras estão todos respondidos.
          </p>
        ) : (
          (estado?.pendencias ?? []).map((p) => (
            <details key={p.modulo} className={styles.modulo}>
              <summary>
                <strong>{NOME_DO_MODULO[p.modulo] ?? p.modulo}</strong>
                <span className={styles.quantas}>{p.quantas} em aberto</span>
              </summary>
              <ul>
                {p.primeiras.map((q) => (
                  <li key={q.chave}>
                    {q.pergunta}
                    <span>{q.contexto}</span>
                  </li>
                ))}
                {p.quantas > p.primeiras.length && (
                  <li className={styles.eMais}>e mais {p.quantas - p.primeiras.length}…</li>
                )}
              </ul>
            </details>
          ))
        )}
      </section>

      {/* --- A conversa --------------------------------------------------- */}
      <section className={styles.conversa}>
        {(estado?.conversa ?? []).length === 0 && proxima && (
          <div className={`${styles.balao} ${styles.doSistema}`}>
            <p>{proxima.pergunta}</p>
          </div>
        )}
        {(estado?.conversa ?? []).map((f) => (
          <div
            key={f.id}
            className={`${styles.balao} ${f.quem === 'DONO' ? styles.doDono : styles.doSistema}`}
          >
            {f.midia && (
              <span className={styles.selo}>{f.midia === 'AUDIO' ? 'áudio' : 'foto'}</span>
            )}
            <p>{f.texto ?? (f.erroLeitura ? 'Não consegui ler este arquivo.' : '…')}</p>
          </div>
        ))}
        <div ref={fimDaConversa} />
      </section>

      <div className={styles.entrada}>
        <textarea
          value={texto}
          rows={2}
          disabled={falando}
          placeholder="ex.: escova sessenta, escova com prancha oitenta, progressiva a partir de trezentos"
          onChange={(e) => setTexto(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault();
              void falar();
            }
          }}
        />
        <div className={styles.botoes}>
          <label className={styles.ghost}>
            Foto ou áudio
            <input
              type="file"
              accept="image/jpeg,image/png,image/webp,audio/*"
              hidden
              disabled={falando}
              onChange={(e) => {
                const arquivo = e.target.files?.[0];
                e.target.value = '';
                if (arquivo) void mandarArquivo(arquivo);
              }}
            />
          </label>
          <button
            className={styles.principal}
            disabled={falando || texto.trim().length === 0}
            onClick={() => void falar()}
          >
            {falando ? 'Anotando…' : 'Mandar'}
          </button>
        </div>
      </div>

      {/* --- O que eu não tive certeza ------------------------------------ */}
      {propostas.length > 0 && (
        <section className={styles.bloco}>
          <h2>Não tive certeza destes</h2>
          <p className={styles.nota}>
            Nada aqui foi gravado. Ou eu não entendi bem, ou o que você disse dava para ler de duas
            formas. Confirme falando de novo, ou descarte.
          </p>
          {propostas.map((r) => (
            <div key={r.id} className={styles.linha}>
              <div>
                <strong>{r.entendido}</strong>
                <span>
                  {NOME_DO_MODULO[r.modulo] ?? r.modulo}
                  {r.confianca != null && ` · confiança ${Math.round(r.confianca * 100)}%`}
                </span>
              </div>
              <button className={styles.ghostPerigo} onClick={() => void desfazer(r.id)}>
                Descartar
              </button>
            </div>
          ))}
        </section>
      )}

      {/* --- O que eu escrevi -------------------------------------------- */}
      {aplicadas.length > 0 && (
        <section className={styles.bloco}>
          <h2>O que eu preenchi</h2>
          <p className={styles.nota}>
            Está no rascunho e nas regras. Se algum estiver errado, desfaça — o valor de antes
            volta.
          </p>
          {aplicadas.map((r) => (
            <div key={r.id} className={styles.linha}>
              <div>
                <strong>{r.entendido}</strong>
                <span>
                  {NOME_DO_MODULO[r.modulo] ?? r.modulo}
                  {r.valorNumero != null &&
                    r.chave.startsWith('SERVICO_PRECO') &&
                    ` · ${moeda(Number(r.valorNumero))}`}
                </span>
              </div>
              <button className={styles.ghost} onClick={() => void desfazer(r.id)}>
                Desfazer
              </button>
            </div>
          ))}
        </section>
      )}

      {/* --- O que eu tentei e não deu ------------------------------------ */}
      {recusadas.length > 0 && (
        <section className={styles.bloco}>
          <h2>Estes eu não consegui gravar</h2>
          <p className={styles.nota}>
            Cada um traz o motivo. Costuma ser serviço que não está no rascunho, ou valor fora de
            qualquer faixa razoável.
          </p>
          {recusadas.map((r) => (
            <div key={r.id} className={styles.linha}>
              <div>
                <strong>{r.entendido}</strong>
                <span>{r.motivo}</span>
              </div>
            </div>
          ))}
        </section>
      )}

      <footer className={styles.rodape}>
        <p className={styles.nota}>
          Preço entra no rascunho, e rascunho não vale para ninguém até você publicar em Serviços.
          Regra e vocabulário valem na hora, e é por isso que cada um deles tem o botão de desfazer
          ao lado.
        </p>
      </footer>
    </main>
  );
}
