'use client';

// Tela de Clientes.
//
// O que ela responde, na ordem em que a dona pergunta:
//
//   1. QUEM ESTÁ ATRASADA PARA VOLTAR. É o dinheiro que já foi conquistado e
//      está escorrendo. Por isso a lista abre ordenada por atraso, e não por
//      ordem alfabética: uma lista alfabética de 300 nomes não responde nada.
//   2. O QUE FALTA SABER de cada uma. Química, consentimento e classificação
//      vêm do banco como pendências — e agora têm onde ser resolvidas.
//   3. O HISTÓRICO: o que ela já fez, de quanto em quanto tempo, quando foi a
//      última vez.
//
// POR QUE NÃO É UM MÓDULO DO CONFIGURADOR. O configurador congela quando a
// configuração está publicada, de propósito: o que o agente usa não muda no
// meio de um atendimento. Ficha de cliente não é configuração. Travar a ficha
// porque o negócio está no ar seria impedir a dona de anotar uma química no
// dia em que ela descobre. Então esta tela mora na operação, ao lado do
// console de WhatsApp, e salva direto.
//
// CUIDADO AO SALVAR. `site_save_client` SUBSTITUI procedimentos, visitas
// manuais e fotos pelo que vier no payload. Mandar a ficha sem esses arrays
// apagaria os três. Por isso tudo que foi carregado volta junto, e as visitas
// que nasceram de um agendamento (appointmentId != null) ficam de fora: o
// banco não as apaga, então reenviá-las criaria uma cópia a cada salvamento.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import styles from './clientes.module.css';

type Pendencia = 'QUIMICA' | 'CONSENTIMENTO' | 'CLASSIFICACAO' | string;

type ClienteDaLista = {
  profileId: string;
  contactId: string;
  name: string | null;
  phone: string | null;
  status: string;
  pendencias: Pendencia[];
  mainProcedure: string | null;
  cadenceProcedure: string | null;
  cadenceDays: number | null;
  cadenceConfidence: string | null;
  cycleRatio: number | null;
  lastVisitOn: string | null;
  daysSinceLastVisit: number | null;
  // Positivo = já passou do ciclo dela. Negativo = ainda dentro do ciclo.
  overdueDays: number | null;
  totalVisits: number | null;
  nextAppointmentAt: string | null;
};

type OpcaoClassificacao = { dimension: string; optionId: string; label: string };

type Procedimento = {
  id: string;
  family: string | null;
  label: string;
  timesDone: number | null;
  lastDoneAt: string | null;
  cadenceDays: number | null;
  cadenceConfidence: string | null;
};

type Visita = {
  id: string;
  occurredOn: string;
  description: string | null;
  family: string | null;
  durationMinutes: number | null;
  amountCents: number | null;
  notes: string | null;
  appointmentId: string | null;
};

type Foto = {
  id: string;
  kind: string;
  storagePath: string;
  caption: string | null;
  takenOn: string | null;
};

type Ficha = {
  profileId: string;
  contactId: string;
  displayName: string | null;
  preferredName: string | null;
  phone: string | null;
  status: string;
  pendencias: Pendencia[];
  lengthOptionId: string | null;
  thicknessOptionId: string | null;
  hasChemistry: boolean | null;
  chemistryKind: string | null;
  chemistryLastAt: string | null;
  chemistryFormol: string | null;
  hasColor: boolean | null;
  colorLastAt: string | null;
  toneWanted: string | null;
  notes: string | null;
  photoConsentGrantedAt: string | null;
  photoConsentRecordedBy: string | null;
  procedures: Procedimento[];
  visits: Visita[];
  photos: Foto[];
};

type Workspace = { tenantId: string; tenantName: string; timezone: string };

type Filtro = 'ATRASADAS' | 'PENDENCIAS' | 'TODAS';

const ROTULO_PENDENCIA: Record<string, string> = {
  QUIMICA: 'química',
  CONSENTIMENTO: 'consentimento',
  CLASSIFICACAO: 'classificação',
};

const ROTULO_FAMILIA: Record<string, string> = {
  COR: 'Cor',
  ALISAMENTO: 'Alisamento',
  TRATAMENTO: 'Tratamento',
  CORTE: 'Corte',
  OUTRO: 'Outro',
};

function data(iso: string | null): string {
  if (!iso) return '—';
  const [ano, mes, dia] = iso.slice(0, 10).split('-');
  return `${dia}/${mes}/${ano}`;
}

function dataHora(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function dinheiro(centavos: number | null): string {
  if (centavos == null) return '—';
  return (centavos / 100).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

// A frase que a dona lê na lista. "há 40 dias, volta a cada 35" diz mais que
// um número solto, e diz sem ela precisar fazer a conta.
function ritmo(c: ClienteDaLista): string {
  if (c.daysSinceLastVisit == null) return 'nunca veio';
  const desde = `há ${c.daysSinceLastVisit} ${c.daysSinceLastVisit === 1 ? 'dia' : 'dias'}`;
  if (c.cadenceDays == null) return desde;
  return `${desde}, volta a cada ${c.cadenceDays}`;
}

function telefoneLegivel(phone: string | null): string {
  if (!phone) return '—';
  const d = phone.replace(/\D/g, '');
  const semPais = d.startsWith('55') ? d.slice(2) : d;
  if (semPais.length < 10) return phone;
  const ddd = semPais.slice(0, 2);
  const resto = semPais.slice(2);
  const meio = resto.length > 8 ? resto.slice(0, 5) : resto.slice(0, 4);
  const fim = resto.length > 8 ? resto.slice(5) : resto.slice(4);
  return `(${ddd}) ${meio}-${fim}`;
}

// Só o que a tela pode editar volta para o banco. O resto vai de volta igual
// ao que veio, porque o salvamento substitui as listas inteiras.
function payloadDaFicha(f: Ficha): Record<string, unknown> {
  return {
    preferredName: f.preferredName ?? '',
    status: f.status,
    lengthOptionId: f.lengthOptionId ?? '',
    thicknessOptionId: f.thicknessOptionId ?? '',
    hasChemistry: f.hasChemistry,
    chemistryKind: f.chemistryKind ?? '',
    chemistryLastAt: f.chemistryLastAt ?? '',
    chemistryFormol: f.chemistryFormol ?? '',
    hasColor: f.hasColor,
    colorLastAt: f.colorLastAt ?? '',
    toneWanted: f.toneWanted ?? '',
    notes: f.notes ?? '',
    photoConsent: f.photoConsentGrantedAt != null,
    procedures: f.procedures,
    // Visita vinda de agendamento não volta: o banco não a apaga, então
    // reenviá-la duplicaria o histórico a cada salvamento.
    visits: f.visits.filter((v) => v.appointmentId == null),
    photos: f.photos,
  };
}

export default function TelaDeClientes() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [lista, setLista] = useState<ClienteDaLista[]>([]);
  const [opcoes, setOpcoes] = useState<OpcaoClassificacao[]>([]);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const [busca, setBusca] = useState('');
  const [filtro, setFiltro] = useState<Filtro>('ATRASADAS');
  const [selecionada, setSelecionada] = useState<string | null>(null);
  const [ficha, setFicha] = useState<Ficha | null>(null);
  const [carregandoFicha, setCarregandoFicha] = useState(false);
  const [sujo, setSujo] = useState(false);
  const [salvando, setSalvando] = useState(false);
  const [aviso, setAviso] = useState<string | null>(null);
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

  const buscarLista = useCallback(async () => {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    try {
      const r = await fetch('/api/clientes', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'loadClients', tenantId, limit: 500 }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'LISTA_INDISPONIVEL');
      const dados = body.data as {
        clients?: ClienteDaLista[];
        classificationOptions?: OpcaoClassificacao[];
      };
      setLista(dados.clients ?? []);
      setOpcoes(dados.classificationOptions ?? []);
      setErro(null);
    } catch {
      setErro('Falha ao carregar a lista de clientes.');
    } finally {
      setCarregando(false);
    }
  }, []);

  useEffect(() => {
    if (!workspace) return;
    void buscarLista();
  }, [workspace, buscarLista]);

  async function abrirFicha(profileId: string) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    // Trocar de cliente com edição pendente perderia o que foi digitado.
    if (sujo && !window.confirm('Você tem alterações não salvas nesta ficha. Descartar?')) return;
    setSelecionada(profileId);
    setCarregandoFicha(true);
    setSujo(false);
    setAviso(null);
    try {
      const r = await fetch('/api/clientes', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'loadClient', tenantId, profileId }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FICHA_INDISPONIVEL');
      setFicha({ ...(body.data as Ficha), profileId });
    } catch {
      setFicha(null);
      setAviso('Não foi possível abrir a ficha desta cliente.');
    } finally {
      setCarregandoFicha(false);
    }
  }

  function editar(mudanca: Partial<Ficha>) {
    setFicha((atual) => (atual ? { ...atual, ...mudanca } : atual));
    setSujo(true);
    setAviso(null);
  }

  async function salvar() {
    const tenantId = tenantRef.current;
    if (!tenantId || !ficha) return;
    setSalvando(true);
    setAviso(null);
    try {
      const r = await fetch('/api/clientes', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          action: 'saveClient',
          tenantId,
          profileId: ficha.profileId,
          payload: payloadDaFicha(ficha),
        }),
      });
      const body = await r.json();
      if (!r.ok) throw new Error(body.error ?? 'FALHA_AO_SALVAR');
      setSujo(false);
      setAviso('Ficha salva.');
      // A lista mostra pendências e status, que acabaram de mudar. Recarregar a
      // ficha também: o banco recalcula pendências no salvamento.
      await Promise.all([buscarLista(), abrirFichaSilenciosa(ficha.profileId)]);
    } catch {
      setAviso('Não foi possível salvar. Nada foi alterado.');
    } finally {
      setSalvando(false);
    }
  }

  // Recarrega a ficha sem o aviso de descarte — usada logo depois de salvar,
  // quando não existe edição pendente por definição.
  async function abrirFichaSilenciosa(profileId: string) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    try {
      const r = await fetch('/api/clientes', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'loadClient', tenantId, profileId }),
      });
      const body = await r.json();
      if (r.ok) setFicha({ ...(body.data as Ficha), profileId });
    } catch {
      /* a ficha na tela continua válida; o salvamento já deu certo */
    }
  }

  const comprimentos = useMemo(
    () => opcoes.filter((o) => o.dimension.toLowerCase().startsWith('compriment')),
    [opcoes]
  );
  const volumes = useMemo(
    () => opcoes.filter((o) => !o.dimension.toLowerCase().startsWith('compriment')),
    [opcoes]
  );

  const atrasadas = useMemo(
    () => lista.filter((c) => (c.overdueDays ?? -1) > 0).length,
    [lista]
  );
  const comPendencia = useMemo(
    () => lista.filter((c) => (c.pendencias ?? []).length > 0).length,
    [lista]
  );

  const visiveis = useMemo(() => {
    const termo = busca.trim().toLowerCase();
    const digitos = termo.replace(/\D/g, '');
    const filtrada = lista.filter((c) => {
      if (filtro === 'ATRASADAS' && (c.overdueDays ?? -1) <= 0) return false;
      if (filtro === 'PENDENCIAS' && (c.pendencias ?? []).length === 0) return false;
      if (!termo) return true;
      const nome = (c.name ?? '').toLowerCase();
      const fone = (c.phone ?? '').replace(/\D/g, '');
      return nome.includes(termo) || (digitos.length >= 3 && fone.includes(digitos));
    });
    // Mais atrasada primeiro. Empate (ou ninguém atrasado) desempata por quem
    // está há mais tempo sem vir.
    return filtrada.sort((a, b) => {
      const atrasoA = a.overdueDays ?? Number.NEGATIVE_INFINITY;
      const atrasoB = b.overdueDays ?? Number.NEGATIVE_INFINITY;
      if (atrasoA !== atrasoB) return atrasoB - atrasoA;
      return (b.daysSinceLastVisit ?? -1) - (a.daysSinceLastVisit ?? -1);
    });
  }, [lista, busca, filtro]);

  if (carregando) {
    return (
      <main className={styles.estado} aria-busy="true">
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>clientes</span>
          <h1>Abrindo a lista.</h1>
          <p>Confirmando o negócio autorizado para esta sessão.</p>
        </section>
      </main>
    );
  }

  if (erro && lista.length === 0) {
    return (
      <main className={styles.estado}>
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>clientes</span>
          <h1>Lista indisponível.</h1>
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
          <span className={styles.eyebrow}>clientes · {workspace?.tenantName ?? ''}</span>
          <h1>Quem já é sua cliente</h1>
        </div>
      </header>

      {erro && <p className={styles.aviso}>{erro}</p>}

      <section className={styles.contadores}>
        {[
          ['na lista', lista.length],
          ['atrasadas para voltar', atrasadas],
          ['com algo a preencher', comPendencia],
        ].map(([rotulo, valor]) => (
          <div key={String(rotulo)} className={styles.contador}>
            <strong>{String(valor)}</strong>
            <span>{rotulo}</span>
          </div>
        ))}
      </section>

      <section className={styles.filtros}>
        <div className={styles.chips}>
          {(
            [
              ['ATRASADAS', 'Atrasadas'],
              ['PENDENCIAS', 'Falta preencher'],
              ['TODAS', 'Todas'],
            ] as Array<[Filtro, string]>
          ).map(([chave, rotulo]) => (
            <button
              key={chave}
              className={`${styles.chip} ${filtro === chave ? styles.chipAtivo : ''}`}
              aria-pressed={filtro === chave}
              onClick={() => setFiltro(chave)}
            >
              {rotulo}
            </button>
          ))}
        </div>
        <input
          className={styles.busca}
          value={busca}
          placeholder="Buscar por nome ou telefone"
          onChange={(e) => setBusca(e.target.value)}
        />
      </section>

      <section className={styles.painel}>
        <aside className={styles.lista}>
          {visiveis.length === 0 && (
            <p className={styles.vazio}>
              {filtro === 'ATRASADAS'
                ? 'Ninguém atrasado para voltar. Veja em "Todas".'
                : 'Nenhuma cliente encontrada.'}
            </p>
          )}
          {visiveis.map((c) => {
            const atrasada = (c.overdueDays ?? -1) > 0;
            return (
              <button
                key={c.profileId}
                className={`${styles.item} ${c.profileId === selecionada ? styles.itemAtivo : ''}`}
                onClick={() => void abrirFicha(c.profileId)}
              >
                <div className={styles.itemLinha}>
                  <strong>{c.name || telefoneLegivel(c.phone)}</strong>
                  {atrasada && (
                    <span className={styles.selo}>
                      {c.overdueDays} {c.overdueDays === 1 ? 'dia' : 'dias'} de atraso
                    </span>
                  )}
                </div>
                <span className={styles.itemPrevia}>
                  {c.mainProcedure ?? 'sem procedimento anotado'} · {ritmo(c)}
                </span>
                {(c.pendencias ?? []).length > 0 && (
                  <span className={styles.itemPendencias}>
                    falta: {c.pendencias.map((p) => ROTULO_PENDENCIA[p] ?? p.toLowerCase()).join(', ')}
                  </span>
                )}
              </button>
            );
          })}
        </aside>

        <div className={styles.ficha}>
          {!ficha && !carregandoFicha && (
            <p className={styles.vazio}>Escolha uma cliente para ver e completar a ficha.</p>
          )}
          {carregandoFicha && <p className={styles.vazio}>Abrindo a ficha…</p>}

          {ficha && !carregandoFicha && (
            <>
              <header className={styles.fichaTopo}>
                <div>
                  <h2>{ficha.preferredName || ficha.displayName || 'Sem nome'}</h2>
                  <span className={styles.fichaFone}>{telefoneLegivel(ficha.phone)}</span>
                </div>
                <button
                  className={`${styles.salvar} ${sujo ? styles.salvarPendente : ''}`}
                  disabled={salvando || !sujo}
                  onClick={() => void salvar()}
                >
                  {salvando ? 'Salvando…' : sujo ? 'Salvar ficha' : 'Tudo salvo'}
                </button>
              </header>

              {aviso && <p className={styles.fichaAviso}>{aviso}</p>}

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>Identificação</span>
                <div className={styles.grade}>
                  <label>
                    Como ela quer ser chamada
                    <input
                      value={ficha.preferredName ?? ''}
                      onChange={(e) => editar({ preferredName: e.target.value })}
                    />
                  </label>
                  <label>
                    Situação
                    <select
                      value={ficha.status}
                      onChange={(e) => editar({ status: e.target.value })}
                    >
                      <option value="PRE_CADASTRO">Pré-cadastro</option>
                      <option value="COMPLETO">Completo</option>
                      <option value="ARQUIVADA">Arquivada</option>
                    </select>
                  </label>
                </div>
                {ficha.status === 'ARQUIVADA' && (
                  <p className={styles.nota}>
                    Ao salvar como arquivada, ela sai desta lista e não aparece mais aqui.
                  </p>
                )}
              </div>

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>Cabelo</span>
                <div className={styles.grade}>
                  <label>
                    Comprimento
                    <select
                      value={ficha.lengthOptionId ?? ''}
                      onChange={(e) => editar({ lengthOptionId: e.target.value || null })}
                    >
                      <option value="">não anotado</option>
                      {comprimentos.map((o) => (
                        <option key={o.optionId} value={o.optionId}>
                          {o.label}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Volume
                    <select
                      value={ficha.thicknessOptionId ?? ''}
                      onChange={(e) => editar({ thicknessOptionId: e.target.value || null })}
                      disabled={volumes.length === 0}
                    >
                      <option value="">não anotado</option>
                      {volumes.map((o) => (
                        <option key={o.optionId} value={o.optionId}>
                          {o.label}
                        </option>
                      ))}
                    </select>
                  </label>
                </div>
                {volumes.length === 0 && (
                  <p className={styles.nota}>
                    Não há opções de volume cadastradas. Elas são criadas em Serviços, no
                    configurador.
                  </p>
                )}
                <label className={styles.campoLargo}>
                  Tom que ela quer alcançar
                  <input
                    value={ficha.toneWanted ?? ''}
                    onChange={(e) => editar({ toneWanted: e.target.value })}
                    placeholder="ex.: castanho iluminado, mechas caramelo"
                  />
                </label>
              </div>

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>Química</span>
                <div className={styles.grade}>
                  <label>
                    Tem química no cabelo?
                    <select
                      value={ficha.hasChemistry == null ? '' : String(ficha.hasChemistry)}
                      onChange={(e) =>
                        editar({ hasChemistry: e.target.value === '' ? null : e.target.value === 'true' })
                      }
                    >
                      <option value="">não sei</option>
                      <option value="true">sim</option>
                      <option value="false">não</option>
                    </select>
                  </label>
                  <label>
                    Qual
                    <input
                      value={ficha.chemistryKind ?? ''}
                      onChange={(e) => editar({ chemistryKind: e.target.value })}
                      placeholder="ex.: progressiva"
                    />
                  </label>
                  <label>
                    Última vez
                    <input
                      type="date"
                      value={ficha.chemistryLastAt ?? ''}
                      onChange={(e) => editar({ chemistryLastAt: e.target.value || null })}
                    />
                  </label>
                  <label>
                    Formol
                    <select
                      value={ficha.chemistryFormol ?? ''}
                      onChange={(e) => editar({ chemistryFormol: e.target.value || null })}
                    >
                      <option value="">não sei</option>
                      <option value="COM_FORMOL">com formol</option>
                      <option value="SEM_FORMOL">sem formol</option>
                      <option value="NAO_SABE">ela não sabe</option>
                    </select>
                  </label>
                </div>
                {/* Regra do salão, e é técnica: formol não sai do cabelo com o
                    tempo, só cortando. Quem lê esta ficha precisa saber disso
                    antes de olhar a data. */}
                {ficha.chemistryFormol === 'COM_FORMOL' && (
                  <p className={styles.nota}>
                    Formol não sai com o tempo, só cortando. A data diz quando foi feita, não que o
                    cabelo esteja livre hoje.
                  </p>
                )}
              </div>

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>Coloração</span>
                <div className={styles.grade}>
                  <label>
                    Cabelo colorido?
                    <select
                      value={ficha.hasColor == null ? '' : String(ficha.hasColor)}
                      onChange={(e) =>
                        editar({ hasColor: e.target.value === '' ? null : e.target.value === 'true' })
                      }
                    >
                      <option value="">não sei</option>
                      <option value="true">sim</option>
                      <option value="false">não</option>
                    </select>
                  </label>
                  <label>
                    Última coloração
                    <input
                      type="date"
                      value={ficha.colorLastAt ?? ''}
                      onChange={(e) => editar({ colorLastAt: e.target.value || null })}
                    />
                  </label>
                </div>
              </div>

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>Fotos</span>
                <label className={styles.consentimento}>
                  <input
                    type="checkbox"
                    checked={ficha.photoConsentGrantedAt != null}
                    onChange={(e) =>
                      editar({
                        photoConsentGrantedAt: e.target.checked ? new Date().toISOString() : null,
                      })
                    }
                  />
                  <span>
                    Ela autorizou guardar fotos do cabelo dela na ficha
                    {ficha.photoConsentGrantedAt && (
                      <em>
                        {' '}
                        · registrado em {dataHora(ficha.photoConsentGrantedAt)}
                        {ficha.photoConsentRecordedBy ? ` por ${ficha.photoConsentRecordedBy}` : ''}
                      </em>
                    )}
                  </span>
                </label>
                <p className={styles.nota}>
                  Marque só se ela autorizou de verdade. Desmarcar apaga o registro do
                  consentimento. Foto que ela manda no meio da conversa não é guardada — o agente lê
                  e descarta.
                </p>
                {ficha.photos.length > 0 && (
                  <p className={styles.nota}>
                    {ficha.photos.length}{' '}
                    {ficha.photos.length === 1 ? 'foto guardada' : 'fotos guardadas'} nesta ficha.
                  </p>
                )}
              </div>

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>Observações</span>
                <textarea
                  className={styles.observacoes}
                  rows={4}
                  value={ficha.notes ?? ''}
                  onChange={(e) => editar({ notes: e.target.value })}
                  placeholder="O que mais importa saber sobre o cabelo dela."
                />
              </div>

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>
                  O que ela já faz ({ficha.procedures.length})
                </span>
                {ficha.procedures.length === 0 ? (
                  <p className={styles.nota}>Nenhum procedimento registrado ainda.</p>
                ) : (
                  <table className={styles.tabela}>
                    <thead>
                      <tr>
                        <th>Procedimento</th>
                        <th>Família</th>
                        <th>Vezes</th>
                        <th>A cada</th>
                        <th>Confiança</th>
                      </tr>
                    </thead>
                    <tbody>
                      {ficha.procedures.map((p) => (
                        <tr key={p.id}>
                          <td>{p.label}</td>
                          <td>{ROTULO_FAMILIA[p.family ?? ''] ?? p.family ?? '—'}</td>
                          <td>{p.timesDone ?? '—'}</td>
                          <td>{p.cadenceDays ? `${p.cadenceDays} dias` : '—'}</td>
                          <td>{(p.cadenceConfidence ?? '').toLowerCase() || '—'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>

              <div className={styles.grupo}>
                <span className={styles.grupoTitulo}>Histórico ({ficha.visits.length})</span>
                {ficha.visits.length === 0 ? (
                  <p className={styles.nota}>Nenhuma visita registrada ainda.</p>
                ) : (
                  <table className={styles.tabela}>
                    <thead>
                      <tr>
                        <th>Quando</th>
                        <th>O que foi</th>
                        <th>Valor</th>
                        <th>Origem</th>
                      </tr>
                    </thead>
                    <tbody>
                      {ficha.visits.map((v) => (
                        <tr key={v.id}>
                          <td>{data(v.occurredOn)}</td>
                          <td>{v.description ?? '—'}</td>
                          <td>{dinheiro(v.amountCents)}</td>
                          <td>{v.appointmentId ? 'agenda' : 'anotada'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>
            </>
          )}
        </div>
      </section>
    </main>
  );
}
