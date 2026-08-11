'use client';

import { useEffect, useState } from 'react';

type BookableService = { id: string; name: string };
type ResourceAssignment = { resourceId: string; quantity: number; capacity: number };
type StepAssignment = {
  stepId: string;
  name: string;
  startMs: number;
  endMs: number;
  memberId: string | null;
  resourceAssignments: ResourceAssignment[];
};
type Candidate = { startMs: number; endMs: number; steps: StepAssignment[] };
type SearchResponse = {
  configurationVersionId: string;
  serviceId: string;
  candidates: Candidate[];
  rejectionCounts: Record<string, number>;
  attemptsMade: number;
  clientExceptionApplied?: boolean;
};
type HoldResponse = { holdId: string; status: string; expiresAt: string };
type ConfirmResponse = { appointmentId: string; status: string };

const REJECTION_LABEL: Record<string, string> = {
  EXCEEDS_OPERATING_WINDOW: 'não cabe inteiro dentro do expediente',
  BEFORE_REFERENCE_CLOCK: 'já passou do horário atual',
  NO_QUALIFIED_MEMBER: 'nenhum profissional cadastrado tem a competência exigida',
  MEMBER_UNAVAILABLE: 'profissional qualificado não está de turno nesse horário',
  MEMBER_OCCUPIED: 'profissional qualificado já está ocupado nesse horário',
  NO_RESOURCE_OF_TYPE: 'nenhum recurso do tipo exigido foi cadastrado',
  RESOURCE_CAPACITY_EXCEEDED: 'recurso exigido está com a capacidade toda ocupada',
};

const ERROR_LABEL: Record<string, string> = {
  NO_PUBLISHED_CONFIGURATION:
    'Ainda não existe nenhuma versão publicada. Vá em Publicar e publique a configuração antes de simular.',
  SERVICE_NOT_BOOKABLE: 'Esse serviço não está disponível para agendamento na versão publicada.',
  HOLD_EXPIRED: 'Essa reserva expirou antes de você confirmar. Busque os horários de novo.',
  MEMBER_OCCUPIED: 'Alguém (ou outro teste) já ocupou esse profissional nesse horário exato.',
  RESOURCE_CAPACITY_EXCEEDED: 'A capacidade do recurso exigido já foi toda ocupada nesse horário.',
};

async function callScheduling(body: Record<string, unknown>) {
  const response = await fetch('/api/scheduling', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const result = (await response.json()) as { error?: string; code?: string; data?: unknown };
  if (!response.ok) {
    const key = result.error ?? '';
    throw new Error(ERROR_LABEL[key] ?? key ?? 'Operação não concluída.');
  }
  return result.data;
}

function formatMoment(ms: number): string {
  return new Date(ms).toLocaleString('pt-BR', {
    weekday: 'short',
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export default function SchedulingSimulator({ tenantId, unitId }: { tenantId: string; unitId: string }) {
  const [services, setServices] = useState<BookableService[]>([]);
  const [configurationVersionId, setConfigurationVersionId] = useState('');
  const [serviceId, setServiceId] = useState('');
  const [loadingServices, setLoadingServices] = useState(true);
  const [searching, setSearching] = useState(false);
  const [busy, setBusy] = useState(false);
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [rejectionCounts, setRejectionCounts] = useState<Record<string, number>>({});
  const [searched, setSearched] = useState(false);
  const [notice, setNotice] = useState('');
  const [customerLabel, setCustomerLabel] = useState('');
  const [clientIdentifier, setClientIdentifier] = useState('');
  const [clientExceptionApplied, setClientExceptionApplied] = useState(false);
  const [activeHold, setActiveHold] = useState<{ holdId: string; expiresAt: string; candidate: Candidate } | null>(
    null
  );
  const [confirmed, setConfirmed] = useState<{ appointmentId: string; candidate: Candidate } | null>(null);

  useEffect(() => {
    if (!tenantId || !unitId) return;
    setLoadingServices(true);
    setServices([]);
    setServiceId('');
    setCandidates([]);
    setSearched(false);
    void callScheduling({ action: 'listBookableServices', tenantId, unitId })
      .then((raw) => {
        const data = raw as { configurationVersionId: string; services: BookableService[] };
        setConfigurationVersionId(data.configurationVersionId);
        setServices(data.services);
        setServiceId(data.services[0]?.id ?? '');
        setNotice('');
      })
      .catch((error) => {
        setNotice(error instanceof Error ? error.message : 'Não foi possível carregar os serviços publicados.');
      })
      .finally(() => setLoadingServices(false));
  }, [tenantId, unitId]);

  async function search() {
    if (!serviceId) return;
    setSearching(true);
    setNotice('');
    setCandidates([]);
    setSearched(false);
    setClientExceptionApplied(false);
    const identifier = clientIdentifier.trim();
    const identifierIsPhone = /^[0-9()\-\s+]{6,}$/.test(identifier);
    try {
      const data = (await callScheduling({
        action: 'searchSlots',
        tenantId,
        unitId,
        serviceId,
        searchFrom: new Date().toISOString(),
        searchDays: 14,
        ...(identifier && identifierIsPhone ? { clientPhoneDigits: identifier.replace(/\D/g, '') } : {}),
        ...(identifier && !identifierIsPhone ? { clientName: identifier } : {}),
      })) as SearchResponse;
      setConfigurationVersionId(data.configurationVersionId);
      setCandidates(data.candidates);
      setRejectionCounts(data.rejectionCounts);
      setClientExceptionApplied(Boolean(data.clientExceptionApplied));
      setSearched(true);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Falha ao buscar horários.');
    } finally {
      setSearching(false);
    }
  }

  async function reserve(candidate: Candidate) {
    setBusy(true);
    setNotice('');
    try {
      const data = (await callScheduling({
        action: 'createHold',
        tenantId,
        unitId,
        configurationVersionId,
        serviceId,
        startsAt: new Date(candidate.startMs).toISOString(),
        endsAt: new Date(candidate.endMs).toISOString(),
        plan: { steps: candidate.steps },
        idempotencyKey: crypto.randomUUID(),
      })) as HoldResponse;
      setActiveHold({ holdId: data.holdId, expiresAt: data.expiresAt, candidate });
      setNotice('Horário reservado provisoriamente. Confirme em até 10 minutos ou ele libera sozinho.');
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Não foi possível reservar — provavelmente alguém levou esse horário primeiro.');
      void search();
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    if (!activeHold) return;
    setBusy(true);
    setNotice('');
    try {
      const data = (await callScheduling({
        action: 'confirmHold',
        tenantId,
        unitId,
        holdId: activeHold.holdId,
        customerLabel: customerLabel.trim() || null,
      })) as ConfirmResponse;
      setConfirmed({ appointmentId: data.appointmentId, candidate: activeHold.candidate });
      setActiveHold(null);
      setCandidates([]);
      setSearched(false);
      setNotice('Agendamento confirmado de verdade no motor — apareceria assim para a cliente.');
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Não foi possível confirmar.');
    } finally {
      setBusy(false);
    }
  }

  async function cancelHold() {
    if (!activeHold) return;
    setBusy(true);
    setNotice('');
    try {
      await callScheduling({ action: 'cancelHold', tenantId, unitId, holdId: activeHold.holdId });
      setActiveHold(null);
      setNotice('Reserva cancelada. O horário voltou a ficar livre.');
      void search();
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Não foi possível cancelar.');
    } finally {
      setBusy(false);
    }
  }

  async function cancelAppointment() {
    if (!confirmed) return;
    setBusy(true);
    setNotice('');
    try {
      await callScheduling({ action: 'cancelAppointment', tenantId, unitId, appointmentId: confirmed.appointmentId });
      setConfirmed(null);
      setNotice('Agendamento de teste cancelado. O horário voltou a ficar livre.');
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Não foi possível cancelar.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className="card">
      <h2>Simulação</h2>
      <p className="hint">
        Este painel usa o <strong>motor de agenda de verdade</strong> — o mesmo que, mais adiante, o
        WhatsApp vai chamar para marcar horários com suas clientes. Nada aqui é encenado: ao reservar e
        confirmar, um agendamento real é criado no banco (você pode cancelar depois, é só um teste). Serve
        para você conferir, antes de ligar o WhatsApp, se os horários que o sistema está oferecendo fazem
        sentido — batem com o expediente, a equipe e os recursos que você cadastrou.
      </p>
      <p className="hint">
        <strong>Como usar:</strong> escolha um serviço publicado, clique em <em>Buscar horários</em> e veja
        as opções que o motor encontrou. Clique em <em>Reservar</em> num horário para travá-lo por 10
        minutos (como se uma cliente estivesse decidindo), depois em <em>Confirmar</em> para virar um
        agendamento de verdade, ou em <em>Cancelar</em> para liberar. Se dois testes tentarem o mesmo
        horário com o mesmo profissional, o segundo é bloqueado automaticamente — é essa trava que impede
        cliente duplicada no futuro.
      </p>

      {loadingServices ? (
        <p className="empty">Carregando serviços publicados…</p>
      ) : services.length === 0 ? (
        <p className="empty">
          Nenhum serviço publicado ainda. Cadastre um serviço com etapas em <strong>Serviços</strong> e
          publique em <strong>Publicar</strong> antes de simular.
        </p>
      ) : (
        <>
          <div className="row slot">
            <label>
              Serviço
              <select value={serviceId} onChange={(event) => setServiceId(event.target.value)}>
                {services.map((service) => (
                  <option key={service.id} value={service.id}>
                    {service.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Nome ou telefone da cliente (opcional)
              <input
                type="text"
                placeholder="Ex.: Maria ou 11987654321"
                value={clientIdentifier}
                onChange={(event) => setClientIdentifier(event.target.value)}
              />
            </label>
            <span />
            <button className="primary" disabled={searching || busy} onClick={() => void search()}>
              {searching ? 'Buscando…' : 'Buscar horários'}
            </button>
          </div>
          <p className="hint small">
            Preenchendo esse campo, a busca também considera as exceções de horário cadastradas
            em <strong>Agenda</strong> para essa cliente (nome exato ou telefone) — testa se o
            sistema realmente abre o horário extra só para ela.
          </p>
          {searched && !activeHold && !confirmed && clientIdentifier.trim() && (
            <p className="hint small">
              {clientExceptionApplied
                ? 'Encontrou uma exceção cadastrada para essa cliente — os horários acima já incluem a janela extra dela.'
                : 'Nenhuma exceção cadastrada para esse nome/telefone — os horários acima são só o expediente normal.'}
            </p>
          )}

          {activeHold && (
            <div className="nested">
              <div className="title minor">
                <h4>Horário reservado (teste) — {formatMoment(activeHold.candidate.startMs)}</h4>
              </div>
              <p className="hint small">
                Expira sozinho às {new Date(activeHold.expiresAt).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })} se ninguém confirmar.
              </p>
              <label>
                Nome da cliente (opcional, só para o teste)
                <input
                  type="text"
                  placeholder="Ex.: Maria (teste)"
                  value={customerLabel}
                  onChange={(event) => setCustomerLabel(event.target.value)}
                />
              </label>
              <div className="actions">
                <button className="danger" disabled={busy} onClick={() => void cancelHold()}>
                  Cancelar reserva
                </button>
                <button className="primary" disabled={busy} onClick={() => void confirm()}>
                  Confirmar agendamento
                </button>
              </div>
            </div>
          )}

          {confirmed && (
            <div className="nested">
              <div className="title minor">
                <h4>Agendamento confirmado — {formatMoment(confirmed.candidate.startMs)}</h4>
              </div>
              <p className="hint small">
                Isso já é um agendamento real no banco (só que de teste). Nenhuma outra reserva consegue
                usar o mesmo profissional/recurso nesse horário enquanto ele existir.
              </p>
              <div className="actions">
                <button className="danger" disabled={busy} onClick={() => void cancelAppointment()}>
                  Cancelar agendamento de teste
                </button>
              </div>
            </div>
          )}

          {!activeHold && !confirmed && searched && (
            <>
              {candidates.length === 0 ? (
                <div className="nested">
                  <p className="empty">
                    Nenhum horário disponível nos próximos 14 dias.
                    {Object.keys(rejectionCounts).length > 0 && (
                      <>
                        {' '}
                        Motivo mais comum:{' '}
                        {Object.entries(rejectionCounts)
                          .sort((left, right) => right[1] - left[1])
                          .slice(0, 1)
                          .map(([code]) => REJECTION_LABEL[code] ?? code)}
                        .
                      </>
                    )}
                  </p>
                </div>
              ) : (
                candidates.map((candidate) => (
                  <div className="step" key={candidate.startMs}>
                    <strong>{formatMoment(candidate.startMs)}</strong>
                    <div className="actions">
                      <button className="secondary" disabled={busy} onClick={() => void reserve(candidate)}>
                        Reservar
                      </button>
                    </div>
                  </div>
                ))
              )}
            </>
          )}
        </>
      )}

      {notice && (
        <p className="hint" role="status">
          {notice}
        </p>
      )}
    </article>
  );
}
