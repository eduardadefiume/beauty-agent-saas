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

// O anexo já subiu para o balde quando chega aqui: o que a tela guarda é o
// endereço dele, não o arquivo. Assim trocar de conversa não perde o upload.
type Anexo = {
  storagePath: string;
  mimeType: string;
  filename: string;
  size: number;
  // URL local só para a pré-visualização. Vive enquanto a aba viver.
  previa: string | null;
};

function tamanhoLegivel(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function relogio(segundos: number): string {
  const m = Math.floor(segundos / 60);
  const s = segundos % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

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
  // Rascunho por conversa: trocar de conversa e voltar não pode apagar o que a
  // pessoa já tinha digitado.
  const [rascunhos, setRascunhos] = useState<Record<string, string>>({});
  // Uma chave de idempotência por rascunho. Ela sobrevive a uma falha de rede
  // de propósito: apertar enviar de novo devolve o mesmo envio em vez de
  // mandar a mensagem duas vezes para a cliente. Só é trocada depois do
  // sucesso, quando começa uma mensagem nova.
  const [chavesEnvio, setChavesEnvio] = useState<Record<string, string>>({});
  const [enviandoMensagem, setEnviandoMensagem] = useState(false);
  const [erroEnvio, setErroEnvio] = useState<string | null>(null);
  // Um anexo por vez, como no WhatsApp: escolher outro troca o anterior.
  const [anexo, setAnexo] = useState<Anexo | null>(null);
  const [subindoAnexo, setSubindoAnexo] = useState(false);
  const [gravando, setGravando] = useState(false);
  const [segundosGravados, setSegundosGravados] = useState(0);
  const gravadorRef = useRef<MediaRecorder | null>(null);
  const pedacosRef = useRef<Blob[]>([]);
  const arquivoRef = useRef<HTMLInputElement | null>(null);
  const cameraRef = useRef<HTMLInputElement | null>(null);
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
  // O contador da gravação. Sem ele a pessoa não sabe se está gravando há três
  // segundos ou há três minutos.
  useEffect(() => {
    if (!gravando) return;
    const id = setInterval(() => setSegundosGravados((v) => v + 1), 1000);
    return () => clearInterval(id);
  }, [gravando]);

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

  // Sobe o arquivo assim que a pessoa escolhe, antes de ela escrever a legenda.
  //
  // Subir só no momento do envio faria o botão "Enviar" travar por segundos com
  // um arquivo grande, e a pessoa não saberia se travou ou se quebrou.
  async function anexarArquivo(arquivo: File) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    setErroEnvio(null);
    setSubindoAnexo(true);
    try {
      const formulario = new FormData();
      formulario.append('tenantId', tenantId);
      formulario.append('file', arquivo);
      const r = await fetch('/api/whatsapp/anexo', { method: 'POST', body: formulario });
      const body = await r.json();
      if (!r.ok) {
        setErroEnvio(
          body.error === 'UNSUPPORTED_MEDIA_TYPE'
            ? `O WhatsApp não aceita esse tipo de arquivo (${body.mime ?? '—'}).`
            : body.error === 'FILE_TOO_LARGE'
              ? 'Arquivo grande demais. O limite do WhatsApp é 16 MB.'
              : 'Não foi possível anexar. Tente de novo.'
        );
        return;
      }
      const dados = body.data as Omit<Anexo, 'previa'>;
      // Solta a prévia anterior: URL de objeto que ninguém revoga fica segurando
      // o arquivo na memória da aba.
      setAnexo((atual) => {
        if (atual?.previa) URL.revokeObjectURL(atual.previa);
        return {
          ...dados,
          previa: arquivo.type.startsWith('image/') ? URL.createObjectURL(arquivo) : null,
        };
      });
    } catch {
      setErroEnvio('Não foi possível anexar. Tente de novo.');
    } finally {
      setSubindoAnexo(false);
    }
  }

  function descartarAnexo() {
    setAnexo((atual) => {
      if (atual?.previa) URL.revokeObjectURL(atual.previa);
      return null;
    });
  }

  // Gravação de áudio no navegador.
  //
  // O formato é escolhido pelo navegador (webm ou mp4, conforme o aparelho) e
  // vai como está — a Meta aceita os dois. Converter no cliente exigiria uma
  // biblioteca pesada para resolver um problema que não existe.
  async function comecarAGravar() {
    setErroEnvio(null);
    try {
      const trilha = await navigator.mediaDevices.getUserMedia({ audio: true });
      const gravador = new MediaRecorder(trilha);
      pedacosRef.current = [];
      gravador.ondataavailable = (e) => {
        if (e.data.size > 0) pedacosRef.current.push(e.data);
      };
      gravador.onstop = () => {
        // Desliga o microfone de verdade. Sem isto o indicador do navegador
        // fica aceso depois de parar, e com razão: a trilha continua aberta.
        trilha.getTracks().forEach((t) => t.stop());
        // O navegador devolve algo como "audio/webm;codecs=opus". A Meta quer
        // o MIME limpo, sem os parâmetros de codec.
        const tipoCompleto = gravador.mimeType || 'audio/webm';
        const tipo = tipoCompleto.split(';')[0] ?? 'audio/webm';
        const blob = new Blob(pedacosRef.current, { type: tipo });
        const extensao = tipo.includes('mp4') ? 'm4a' : 'webm';
        void anexarArquivo(new File([blob], `audio-${Date.now()}.${extensao}`, { type: tipo }));
      };
      gravador.start();
      gravadorRef.current = gravador;
      setSegundosGravados(0);
      setGravando(true);
    } catch {
      setErroEnvio('Não consegui acessar o microfone. Verifique a permissão do navegador.');
    }
  }

  function pararDeGravar(descartar: boolean) {
    const gravador = gravadorRef.current;
    if (!gravador) return;
    if (descartar) gravador.onstop = null;
    gravador.stop();
    if (descartar) {
      gravador.stream.getTracks().forEach((t) => t.stop());
      pedacosRef.current = [];
    }
    gravadorRef.current = null;
    setGravando(false);
  }

  // O dono respondendo pela tela.
  //
  // Fora da janela de 24h a Meta recusa texto livre -- só modelo aprovado. A
  // função do banco devolve SERVICE_WINDOW_CLOSED e a tela diz isso com todas
  // as letras, em vez de deixar a mensagem sumir sem explicação.
  async function enviarMensagem() {
    const tenantId = tenantRef.current;
    const conversationId = selecionada;
    if (!tenantId || !conversationId) return;
    const texto = (rascunhos[conversationId] ?? '').trim();
    if ((texto.length === 0 && !anexo) || enviandoMensagem || subindoAnexo) return;

    const chave = chavesEnvio[conversationId] ?? crypto.randomUUID();
    if (!chavesEnvio[conversationId]) {
      setChavesEnvio((atual) => ({ ...atual, [conversationId]: chave }));
    }

    setEnviandoMensagem(true);
    setErroEnvio(null);
    try {
      const r = await fetch('/api/whatsapp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          action: 'sendMessage',
          tenantId,
          conversationId,
          text: texto,
          idempotencyKey: chave,
          mediaStoragePath: anexo?.storagePath,
          mediaMimeType: anexo?.mimeType,
          mediaFilename: anexo?.filename,
        }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA');
      // O console embrulha o retorno da RPC em `data`. Ler o nível errado aqui
      // faria uma recusa da Meta passar por sucesso e o rascunho ser apagado
      // sem a mensagem ter saído.
      const resultado = (body?.data ?? {}) as { ok?: boolean; reason?: string };
      if (resultado.ok === false) {
        setErroEnvio(
          resultado.reason === 'SERVICE_WINDOW_CLOSED'
            ? 'A janela de 24h fechou. Só dá para escrever livremente até 24h depois da última mensagem da cliente — fora disso a Meta exige um modelo aprovado.'
            : resultado.reason === 'BODY_TOO_LONG'
              ? 'Mensagem longa demais. O limite do WhatsApp é 4096 caracteres.'
              : 'Não foi possível enviar. Tente de novo.'
        );
        return;
      }
      // Só limpa depois de o banco aceitar. Rascunho apagado com envio falho
      // é texto perdido.
      setRascunhos((atual) => ({ ...atual, [conversationId]: '' }));
      descartarAnexo();
      setChavesEnvio((atual) => {
        const proximo = { ...atual };
        delete proximo[conversationId];
        return proximo;
      });
      await buscar();
    } catch {
      setErroEnvio('Não foi possível enviar. Tente de novo — a mensagem não sai duas vezes.');
    } finally {
      setEnviandoMensagem(false);
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
          {/* Sem isto não havia caminho de volta: quem entrava aqui só saía
              pelo botão do navegador. */}
          <a className={styles.voltar} href="/">
            ← Voltar ao configurador
          </a>
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

              {/* A caixa de digitação. É ela que transforma esta tela de
                  espelho em telefone -- um número na Cloud API sai do
                  aplicativo do WhatsApp Business, então esta é a única porta
                  que resta para o dono falar com a cliente. */}
              <div className={styles.compositor}>
                {!conversa.windowOpen ? (
                  <p className={styles.janelaFechadaAviso}>
                    <strong>Janela de 24h fechada.</strong> Texto livre só sai até 24h depois da
                    última mensagem da cliente — é regra da Meta, não do sistema. Fora disso, só
                    modelo aprovado. Assim que ela escrever, a caixa volta.
                  </p>
                ) : gravando ? (
                  <div className={styles.gravando}>
                    <span className={styles.pontoVermelho} aria-hidden="true" />
                    <strong>Gravando… {relogio(segundosGravados)}</strong>
                    <button className={styles.ghost} onClick={() => pararDeGravar(true)}>
                      Descartar
                    </button>
                    <button className={styles.enviar} onClick={() => pararDeGravar(false)}>
                      Parar e anexar
                    </button>
                  </div>
                ) : (
                  <>
                    {anexo && (
                      <div className={styles.anexo}>
                        {anexo.previa ? (
                          <img className={styles.anexoPrevia} src={anexo.previa} alt="" />
                        ) : (
                          <span className={styles.anexoIcone} aria-hidden="true">
                            {anexo.mimeType.startsWith('audio/')
                              ? '🎙'
                              : anexo.mimeType.startsWith('video/')
                                ? '🎬'
                                : '📄'}
                          </span>
                        )}
                        <div className={styles.anexoTexto}>
                          <strong>{anexo.filename}</strong>
                          <span>{tamanhoLegivel(anexo.size)}</span>
                        </div>
                        <button className={styles.ghost} onClick={descartarAnexo}>
                          Remover
                        </button>
                      </div>
                    )}

                    {/* Entradas escondidas: o clipe abre a galeria, a câmera
                        abre a câmera direto no celular (capture). São dois
                        botões porque no aparelho são dois gestos diferentes. */}
                    <input
                      ref={arquivoRef}
                      type="file"
                      hidden
                      accept="image/jpeg,image/png,image/webp,video/mp4,video/3gpp,audio/aac,audio/mp4,audio/mpeg,audio/amr,audio/ogg,application/pdf"
                      onChange={(e) => {
                        const f = e.target.files?.[0];
                        if (f) void anexarArquivo(f);
                        e.target.value = '';
                      }}
                    />
                    <input
                      ref={cameraRef}
                      type="file"
                      hidden
                      accept="image/*"
                      capture="environment"
                      onChange={(e) => {
                        const f = e.target.files?.[0];
                        if (f) void anexarArquivo(f);
                        e.target.value = '';
                      }}
                    />

                    <textarea
                      className={styles.campoMensagem}
                      value={rascunhos[conversa.id] ?? ''}
                      placeholder="Escreva para a cliente…"
                      rows={2}
                      maxLength={4096}
                      disabled={enviandoMensagem}
                      onChange={(e) =>
                        setRascunhos((atual) => ({ ...atual, [conversa.id]: e.target.value }))
                      }
                      onKeyDown={(e) => {
                        // Enter envia, Shift+Enter quebra linha -- é o que a
                        // mão de quem usa WhatsApp já espera.
                        if (e.key === 'Enter' && !e.shiftKey) {
                          e.preventDefault();
                          void enviarMensagem();
                        }
                      }}
                    />
                    <div className={styles.compositorAcoes}>
                      <div className={styles.ferramentas}>
                        <button
                          className={styles.ferramenta}
                          title="Anexar arquivo"
                          aria-label="Anexar arquivo"
                          disabled={subindoAnexo}
                          onClick={() => arquivoRef.current?.click()}
                        >
                          📎
                        </button>
                        <button
                          className={styles.ferramenta}
                          title="Tirar foto"
                          aria-label="Tirar foto"
                          disabled={subindoAnexo}
                          onClick={() => cameraRef.current?.click()}
                        >
                          📷
                        </button>
                        <button
                          className={styles.ferramenta}
                          title="Gravar áudio"
                          aria-label="Gravar áudio"
                          disabled={subindoAnexo}
                          onClick={() => void comecarAGravar()}
                        >
                          🎙
                        </button>
                        {subindoAnexo && <span className={styles.subindo}>anexando…</span>}
                      </div>
                      <span className={styles.contadorCaracteres}>
                        {(rascunhos[conversa.id] ?? '').length}/4096
                      </span>
                      <button
                        className={styles.enviar}
                        onClick={() => void enviarMensagem()}
                        disabled={
                          enviandoMensagem ||
                          subindoAnexo ||
                          ((rascunhos[conversa.id] ?? '').trim().length === 0 && !anexo)
                        }
                      >
                        {enviandoMensagem ? 'Enviando…' : 'Enviar'}
                      </button>
                    </div>
                  </>
                )}
                {erroEnvio && <p className={styles.erroEnvio}>{erroEnvio}</p>}
              </div>
            </>
          )}
        </div>
      </section>
    </main>
  );
}
