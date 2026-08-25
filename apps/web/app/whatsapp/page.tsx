'use client';

// Console de WhatsApp.
//
// Existe porque a Duda pediu para ver o agente trabalhando em tempo real e ter
// como pará-lo sem depender de ninguém. Duas coisas moldam a tela inteira:
//
//   1. O botão de parada fica no topo, sempre visível, nunca atrás de um menu.
//      Botão de emergência que precisa ser procurado não é botão de emergência.
//   2. A conversa mostra QUEM falou -- agente, equipe ou sistema -- e, quando o
//      agente decidiu não responder, mostra por quê. Sem isso a tela mostraria
//      mensagens; com isso ela mostra o comportamento, que é o que ela quer
//      julgar antes de soltar o agente para uma cliente de verdade.
//
// A atualização é por sondagem a cada 5 segundos, e não por Realtime. Para uma
// pessoa olhando uma tela, 5 segundos é indistinguível de instantâneo, e a
// sondagem não depende de conexão persistente nem de política de RLS em canal
// -- é menos coisa para quebrar no dia do teste.

import { useCallback, useEffect, useRef, useState } from 'react';
import styles from './whatsapp.module.css';

const INTERVALO_MS = 5000;

type Mensagem = {
  id: string;
  direction: 'INBOUND' | 'OUTBOUND';
  text: string | null;
  at: string;
  actor: string | null;
  deliveryStatus: string | null;
  agentMayReply: boolean | null;
  agentDecision: string | null;
  agentDecisionReason: string | null;
};

type Conversa = {
  id: string;
  status: string;
  contactName: string | null;
  whatsapp: string | null;
  lastMessageAt: string | null;
  lastInboundAt: string | null;
  windowOpen: boolean;
  minutesRemaining: number;
  messages: Mensagem[];
};

// Conversa que o agente desistiu de atender depois de cinco tropecos. Do outro
// lado tem uma cliente que escreveu e nao recebeu nada -- por isso isto aparece
// na tela em vez de morrer num log.
type ConversaEstacionada = {
  conversationId: string;
  contactName: string | null;
  whatsapp: string | null;
  failures: number;
  lastError: string | null;
  parkedAt: string;
  lastInboundAt: string | null;
};

type PerguntaAoDono = {
  id: string;
  conversationId: string;
  contactName: string | null;
  whatsapp: string | null;
  question: string;
  contextSummary: string | null;
  createdAt: string;
  waitingSeconds: number;
};

type Console = {
  automation: {
    enabled: boolean;
    changedAt: string | null;
    changedByEmail: string | null;
    reason: string | null;
  };
  connection: {
    id: string;
    channel: string;
    senderId: string | null;
    mode: string | null;
    status: string;
    lastWebhookAt: string | null;
  } | null;
  ownerQuestions: PerguntaAoDono[];
  counters: {
    conversationsOpen: number;
    windowOpen: number;
    messages24h: number;
    outboxPending: number;
    outboxFailed: number;
    agentReplies24h: number;
    ownerQuestionsPending: number;
    handoffs24h: number;
  };
  conversations: Conversa[];
};

type Workspace = { tenantId: string; tenantName: string; timezone: string };

function hora(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function desde(iso: string | null): string {
  if (!iso) return 'nunca';
  const segundos = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
  if (segundos < 60) return `há ${segundos}s`;
  if (segundos < 3600) return `há ${Math.floor(segundos / 60)}min`;
  if (segundos < 86400) return `há ${Math.floor(segundos / 3600)}h`;
  return `há ${Math.floor(segundos / 86400)}d`;
}

function janela(minutos: number): string {
  if (minutos <= 0) return 'fechada';
  const h = Math.floor(minutos / 60);
  return h > 0 ? `${h}h restantes` : `${minutos}min restantes`;
}

// Rótulo de quem escreveu. O banco guarda o ator em metadata; aqui ele vira
// uma palavra que a Duda lê sem traduzir.
function quemFalou(m: Mensagem): string {
  if (m.direction === 'INBOUND') return 'Cliente';
  if (m.actor === 'AGENT') return 'Agente';
  if (m.actor === 'HUMAN') return 'Equipe';
  return 'Sistema';
}

export default function WhatsAppConsole() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [dados, setDados] = useState<Console | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [selecionada, setSelecionada] = useState<string | null>(null);
  const [atualizadoEm, setAtualizadoEm] = useState<string | null>(null);
  const [aoVivo, setAoVivo] = useState(true);
  const [salvandoChave, setSalvandoChave] = useState(false);
  const [confirmandoLigar, setConfirmandoLigar] = useState(false);
  // Rascunho por pergunta. Fica no componente e não no servidor: é texto que a
  // pessoa está digitando, não estado do sistema.
  const [estacionadas, setEstacionadas] = useState<ConversaEstacionada[]>([]);
  const [retomando, setRetomando] = useState<string | null>(null);
  const [respostas, setRespostas] = useState<Record<string, string>>({});
  const [enviandoResposta, setEnviandoResposta] = useState<string | null>(null);
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
      // As duas leituras saem juntas: o console e a lista de conversas que o
      // agente abandonou. Sao chamadas separadas de proposito -- estacionar uma
      // conversa nao e um contador a mais do console, e uma fila de resgate com
      // vida propria.
      const [r, rEstacionadas] = await Promise.all([
        fetch('/api/whatsapp', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ action: 'whatsappConsole', tenantId, limit: 20 }),
        }),
        fetch('/api/whatsapp', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ action: 'agentParkedConversations', tenantId, limit: 50 }),
        }),
      ]);
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'CONSOLE_INDISPONIVEL');
      setDados(body.data as Console);
      // Falha so na lista de estacionadas nao derruba o console inteiro.
      if (rEstacionadas.ok) {
        const corpo = await rEstacionadas.json();
        setEstacionadas((corpo.data ?? []) as ConversaEstacionada[]);
      }
      setAtualizadoEm(new Date().toISOString());
      setErro(null);
    } catch {
      // Falha de rede não apaga a tela: o operador continua vendo a última foto
      // e o aviso de que ela envelheceu.
      setErro('Falha ao atualizar. Mostrando a última leitura.');
    } finally {
      setCarregando(false);
    }
  }, []);

  useEffect(() => {
    if (!workspace) return;
    void buscar();
    if (!aoVivo) return;
    const id = setInterval(() => void buscar(), INTERVALO_MS);
    return () => clearInterval(id);
  }, [workspace, aoVivo, buscar]);

  // Faz o "atualizado há Xs" andar mesmo entre as buscas.
  const [, force] = useState(0);
  useEffect(() => {
    const id = setInterval(() => force((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, []);

  async function mudarChave(ligar: boolean) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    setSalvandoChave(true);
    try {
      const r = await fetch('/api/whatsapp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          action: 'setAgentAutomation',
          tenantId,
          enabled: ligar,
          reason: ligar ? 'Ligado pelo console.' : 'Parada de emergência pelo console.',
        }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA');
      await buscar();
      setConfirmandoLigar(false);
    } catch {
      setErro('Não foi possível mudar a chave. Tente de novo.');
    } finally {
      setSalvandoChave(false);
    }
  }

  async function responderPergunta(questionId: string) {
    const tenantId = tenantRef.current;
    const texto = (respostas[questionId] ?? '').trim();
    if (!tenantId || texto.length === 0) return;
    setEnviandoResposta(questionId);
    try {
      const r = await fetch('/api/whatsapp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          action: 'answerOwnerQuestion',
          tenantId,
          questionId,
          answer: texto,
        }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA');
      setRespostas((atual) => {
        const proximo = { ...atual };
        delete proximo[questionId];
        return proximo;
      });
      await buscar();
    } catch {
      setErro('Não foi possível salvar a resposta. Tente de novo.');
    } finally {
      setEnviandoResposta(null);
    }
  }

  async function descartarPergunta(questionId: string) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    setEnviandoResposta(questionId);
    try {
      await fetch('/api/whatsapp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'dismissOwnerQuestion', tenantId, questionId }),
      });
      await buscar();
    } catch {
      setErro('Não foi possível descartar. Tente de novo.');
    } finally {
      setEnviandoResposta(null);
    }
  }

  // Devolver a conversa ao agente e ato humano e deliberado: alguem olhou,
  // entendeu o que travou e decidiu tentar de novo. Por isso tem confirmacao --
  // se a causa nao foi resolvida, ela vai estacionar de novo em meia hora.
  async function retomarConversa(conversationId: string, nome: string | null) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    const quem = nome ?? 'esta cliente';
    if (!window.confirm(`Devolver a conversa de ${quem} para o agente tentar de novo?`)) return;
    setRetomando(conversationId);
    try {
      const r = await fetch('/api/whatsapp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'resumeParkedConversation', tenantId, conversationId }),
      });
      if (!r.ok) throw new Error('RETOMADA_FALHOU');
      await buscar();
    } catch {
      setErro('Não foi possível devolver a conversa ao agente. Tente de novo.');
    } finally {
      setRetomando(null);
    }
  }

  if (carregando && !dados) {
    return (
      <main className={styles.estado} aria-busy="true">
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>whatsapp</span>
          <h1>Abrindo o console.</h1>
          <p>Confirmando o negócio autorizado para esta sessão.</p>
        </section>
      </main>
    );
  }

  if (!dados) {
    return (
      <main className={styles.estado}>
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>whatsapp</span>
          <h1>Console indisponível.</h1>
          <p>{erro ?? 'Não foi possível carregar os dados do canal.'}</p>
        </section>
      </main>
    );
  }

  const ligado = dados.automation.enabled;
  const conversas = dados.conversations ?? [];
  const conversa = conversas.find((c) => c.id === selecionada) ?? conversas[0] ?? null;

  return (
    <main className={styles.shell}>
      <header className={styles.topo}>
        <div>
          <span className={styles.eyebrow}>whatsapp · {workspace?.tenantName ?? ''}</span>
          <h1>Conversas e agente</h1>
        </div>
        <div className={styles.frescor}>
          <button
            className={styles.ghost}
            onClick={() => setAoVivo((v) => !v)}
            aria-pressed={aoVivo}
          >
            {aoVivo ? 'ao vivo' : 'pausado'}
          </button>
          <span>atualizado {desde(atualizadoEm)}</span>
        </div>
      </header>

      {/* A parada de emergência. Primeira coisa da página, sempre. */}
      <section className={ligado ? styles.chaveLigada : styles.chaveDesligada}>
        <div className={styles.chaveTexto}>
          <strong>{ligado ? 'Resposta automática LIGADA' : 'Resposta automática DESLIGADA'}</strong>
          <p>
            {ligado
              ? 'O agente está respondendo sozinho as clientes liberadas. Parar cala o agente na hora — a equipe continua respondendo normalmente.'
              : 'Nenhuma mensagem sai em nome do agente. A equipe continua respondendo normalmente pelo aplicativo.'}
          </p>
          {dados.automation.changedAt && (
            <small>
              última mudança {desde(dados.automation.changedAt)}
              {dados.automation.changedByEmail ? ` por ${dados.automation.changedByEmail}` : ''}
            </small>
          )}
        </div>

        {ligado ? (
          <button
            className={styles.parar}
            disabled={salvandoChave}
            onClick={() => void mudarChave(false)}
          >
            {salvandoChave ? 'parando…' : 'PARAR AGORA'}
          </button>
        ) : confirmandoLigar ? (
          // Ligar pede confirmação; parar não. A assimetria é proposital: o
          // caminho perigoso é o que solta o agente para falar com cliente.
          <div className={styles.confirmar}>
            <span>Liberar o agente para responder?</span>
            <button
              className={styles.ligar}
              disabled={salvandoChave}
              onClick={() => void mudarChave(true)}
            >
              {salvandoChave ? 'ligando…' : 'sim, ligar'}
            </button>
            <button className={styles.ghost} onClick={() => setConfirmandoLigar(false)}>
              cancelar
            </button>
          </div>
        ) : (
          <button className={styles.ligar} onClick={() => setConfirmandoLigar(true)}>
            ligar resposta automática
          </button>
        )}
      </section>

      {erro && <p className={styles.aviso}>{erro}</p>}

      {/* As perguntas do agente. Ficam logo abaixo do botão de parada porque
          cada linha parada aqui é uma cliente esperando sem saber que espera.
          Responder é digitar uma frase — nada de formulário: quem atende está
          entre uma cliente e outra, e pergunta que exige três campos não é
          respondida, vira fila. */}
      {(dados.ownerQuestions ?? []).length > 0 && (
        <section className={styles.perguntas}>
          <header className={styles.perguntasTopo}>
            <strong>O agente precisa de você</strong>
            <span>
              {dados.ownerQuestions.length}{' '}
              {dados.ownerQuestions.length === 1 ? 'cliente esperando' : 'clientes esperando'}
            </span>
          </header>

          {dados.ownerQuestions.map((p) => (
            <article key={p.id} className={styles.pergunta}>
              <div className={styles.perguntaCabeca}>
                <strong>{p.contactName ?? p.whatsapp ?? 'Sem nome'}</strong>
                <span>esperando {desde(p.createdAt)}</span>
              </div>
              <p className={styles.perguntaTexto}>{p.question}</p>
              {p.contextSummary && <p className={styles.perguntaContexto}>{p.contextSummary}</p>}
              <div className={styles.perguntaAcoes}>
                <input
                  className={styles.perguntaCampo}
                  placeholder="Responda em uma frase…"
                  value={respostas[p.id] ?? ''}
                  disabled={enviandoResposta === p.id}
                  onChange={(e) => setRespostas((atual) => ({ ...atual, [p.id]: e.target.value }))}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') void responderPergunta(p.id);
                  }}
                />
                <button
                  className={styles.ligar}
                  disabled={enviandoResposta === p.id || !(respostas[p.id] ?? '').trim()}
                  onClick={() => void responderPergunta(p.id)}
                >
                  {enviandoResposta === p.id ? 'enviando…' : 'responder'}
                </button>
                <button
                  className={styles.ghost}
                  disabled={enviandoResposta === p.id}
                  onClick={() => void descartarPergunta(p.id)}
                >
                  descartar
                </button>
              </div>
            </article>
          ))}
        </section>
      )}

      {/* Conversas que o agente abandonou. Vem depois das perguntas porque sao
          mais raras, mas sao mais graves: na pergunta ao dono a cliente esta em
          espera consciente; aqui ela escreveu e nao recebeu nada. Tom grave em
          vez de ambar para nao se confundir com "trabalho esperando", e nunca
          vermelho -- vermelho e so do botao de parada. */}
      {estacionadas.length > 0 && (
        <section className={styles.estacionadas}>
          <header className={styles.estacionadasTopo}>
            <strong>O agente desistiu destas conversas</strong>
            <span>
              {estacionadas.length}{' '}
              {estacionadas.length === 1 ? 'cliente sem resposta' : 'clientes sem resposta'}
            </span>
          </header>
          {estacionadas.map((c) => (
            <article key={c.conversationId} className={styles.estacionada}>
              <div className={styles.perguntaCabeca}>
                <strong>{c.contactName ?? c.whatsapp ?? 'Sem nome'}</strong>
                <span>parou {desde(c.parkedAt)}</span>
              </div>
              <p className={styles.perguntaTexto}>
                Tentou {c.failures} {c.failures === 1 ? 'vez' : 'vezes'} e não conseguiu responder.
                Alguém precisa atender essa cliente à mão.
              </p>
              {c.lastError && <p className={styles.estacionadaErro}>{c.lastError}</p>}
              <div className={styles.perguntaAcoes}>
                <button
                  className={styles.ghost}
                  disabled={retomando === c.conversationId}
                  onClick={() => void retomarConversa(c.conversationId, c.contactName)}
                >
                  {retomando === c.conversationId ? 'devolvendo…' : 'devolver ao agente'}
                </button>
              </div>
            </article>
          ))}
        </section>
      )}

      <section className={styles.conexao}>
        {dados.connection ? (
          <>
            <span className={styles.pill}>{dados.connection.status}</span>
            <span>número {dados.connection.senderId ?? '—'}</span>
            <span>último evento da Meta {desde(dados.connection.lastWebhookAt)}</span>
          </>
        ) : (
          <span className={styles.pillAlerta}>nenhum número de WhatsApp conectado</span>
        )}
      </section>

      <section className={styles.contadores}>
        {[
          ['conversas abertas', dados.counters.conversationsOpen],
          ['dentro da janela de 24h', dados.counters.windowOpen],
          ['mensagens em 24h', dados.counters.messages24h],
          ['respostas do agente em 24h', dados.counters.agentReplies24h],
          ['esperando você responder', dados.counters.ownerQuestionsPending],
          ['passadas para a equipe', dados.counters.handoffs24h],
          ['na fila de envio', dados.counters.outboxPending],
          ['falhas de envio', dados.counters.outboxFailed],
        ].map(([rotulo, valor]) => (
          <div key={String(rotulo)} className={styles.contador}>
            <strong>{valor}</strong>
            <span>{rotulo}</span>
          </div>
        ))}
      </section>

      <section className={styles.painel}>
        <aside className={styles.lista}>
          {conversas.length === 0 && <p className={styles.vazio}>Nenhuma conversa ainda.</p>}
          {conversas.map((c) => (
            <button
              key={c.id}
              className={c.id === conversa?.id ? styles.itemAtivo : styles.item}
              onClick={() => setSelecionada(c.id)}
            >
              <strong>{c.contactName ?? c.whatsapp ?? 'Sem nome'}</strong>
              <span className={styles.itemPrevia}>
                {c.messages.at(-1)?.text?.slice(0, 60) ?? '—'}
              </span>
              <span className={c.windowOpen ? styles.janelaAberta : styles.janelaFechada}>
                {c.windowOpen ? janela(c.minutesRemaining) : 'janela fechada'} ·{' '}
                {desde(c.lastMessageAt)}
              </span>
            </button>
          ))}
        </aside>

        <div className={styles.conversa}>
          {!conversa ? (
            <p className={styles.vazio}>Escolha uma conversa.</p>
          ) : (
            <>
              <header className={styles.conversaTopo}>
                <div>
                  <strong>{conversa.contactName ?? 'Sem nome'}</strong>
                  <span>{conversa.whatsapp}</span>
                </div>
                <span className={conversa.windowOpen ? styles.janelaAberta : styles.janelaFechada}>
                  {conversa.windowOpen
                    ? `janela aberta · ${janela(conversa.minutesRemaining)}`
                    : 'janela de 24h fechada'}
                </span>
              </header>

              <div className={styles.baloes}>
                {conversa.messages.map((m) => (
                  <div key={m.id}>
                    <article
                      className={m.direction === 'INBOUND' ? styles.balaoEntra : styles.balaoSai}
                    >
                      <span className={styles.autor}>
                        {quemFalou(m)}
                        {m.direction === 'OUTBOUND' && m.deliveryStatus
                          ? ` · ${m.deliveryStatus.toLowerCase()}`
                          : ''}
                      </span>
                      <p>{m.text}</p>
                      <time>{hora(m.at)}</time>
                    </article>

                    {/* O que o agente decidiu ao ver esta mensagem. É a linha
                        que transforma a tela de "histórico" em "comportamento". */}
                    {m.direction === 'INBOUND' && m.agentDecision && (
                      <p
                        className={
                          m.agentDecision === 'REPLY' ? styles.decisaoOk : styles.decisaoPassou
                        }
                      >
                        {m.agentDecision === 'REPLY'
                          ? 'agente respondeu'
                          : m.agentDecision === 'HANDOFF'
                            ? 'agente passou para a equipe'
                            : 'agente falhou'}
                        {m.agentDecisionReason ? ` — ${m.agentDecisionReason}` : ''}
                      </p>
                    )}
                    {m.direction === 'INBOUND' && !m.agentDecision && m.agentMayReply === false && (
                      <p className={styles.decisaoPassou}>
                        cliente fora da lista de resposta automática — é da equipe
                      </p>
                    )}
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </section>
    </main>
  );
}
