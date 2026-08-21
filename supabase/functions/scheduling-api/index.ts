import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import {
  compileServiceTimeline,
  findAvailableSlots,
  resolveDynamicShiftWindows,
  resolveOperatingWindows,
  resolveStrandTestWindow,
  SchedulingConfigurationError,
  type AbsoluteWindow,
  type CandidateSlot,
  type DynamicShift,
  type EligibleMember,
  type EligibleResource,
  type OccupancyRange,
  type PublishedStep,
  type WeeklyOperatingHours,
  type WeeklyServiceLimit,
} from './scheduling-engine.ts';

// Motor de agenda — busca de horários, hold e confirmação. Mesmo padrão de
// autenticação do owner-console-api (JWT já verificado pelo gateway do
// projeto -> decodifica o e-mail -> chama RPCs public.schedule_* via
// service_role, que validam o tenant contra app.site_identities).

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

const SITE_PROJECT_ID = 'owner-console-v1';

// Identidade de serviço do agente em app.site_identities. Não tem login: só
// existe como linha de autorização, e só vale acompanhada do token de worker.
const AGENT_IDENTITY_EMAIL = 'agente@sistema.interno';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function emailFromVerifiedJwt(authorizationHeader: string | null): string | null {
  if (!authorizationHeader?.startsWith('Bearer ')) return null;
  const token = authorizationHeader.slice('Bearer '.length);
  const segments = token.split('.');
  if (segments.length !== 3) return null;

  try {
    const base64 = segments[1].replace(/-/g, '+').replace(/_/g, '/');
    const payload = JSON.parse(atob(base64)) as { email?: unknown };
    return typeof payload.email === 'string' && payload.email.length > 0 && payload.email.length <= 320
      ? payload.email
      : null;
  } catch {
    return null;
  }
}

// Resolve o offset UTC (minutos) do fuso IANA da unidade para uma data de
// referência, usando Intl (ICU completo no Deno) — correto mesmo em fusos
// com horário de verão, para essa data específica. Ver o aviso de limite em
// scheduling-engine.ts sobre janelas de busca que atravessam uma transição.
function resolveUtcOffsetMinutes(timeZone: string, atDate: Date): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(atDate);

  const map: Record<string, string> = {};
  for (const part of parts) map[part.type] = part.value;

  const asIfUtc = Date.UTC(
    Number(map.year),
    Number(map.month) - 1,
    Number(map.day),
    Number(map.hour),
    Number(map.minute),
    Number(map.second)
  );

  return Math.round((asIfUtc - atDate.getTime()) / 60_000);
}

function parseLocalTimeToMinutes(value: string): number {
  // "09:00:00" ou "09:00" -> minutos desde 00:00.
  const [hours, minutes] = value.split(':').map(Number);
  return hours * 60 + minutes;
}

interface SnapshotQualifier {
  qualifier_option_id: string | null;
  custom_value: string | null;
}

interface SnapshotStep {
  id: string;
  name: string;
  position: number;
  duration_minutes: number;
  kind: 'ACTIVE' | 'PASSIVE';
  releases_member: boolean;
  skillRequirements: { skill_id: string; quantity: number; qualifier: SnapshotQualifier | null }[];
  resourceRequirements: { resource_type_id: string; quantity: number; retain_until_service_end: boolean }[];
}

interface Snapshot {
  operatingHours: { weekday: number; starts_at: string; ends_at: string }[];
  serviceLimits: { weekday: number; latest_end_time: string }[];
  clientExceptions: {
    client_name: string;
    client_phone_digits: string | null;
    weekday: number;
    starts_at: string;
    ends_at: string;
  }[];
  teamMembers: {
    id: string;
    name: string;
    status: string;
    availability_mode: 'FIXED' | 'HYBRID' | 'DYNAMIC';
    skillIds: string[];
    skillQualifiers: { skill_id: string; qualifier_option_id: string | null; custom_value: string | null }[];
    availability: { weekday: number; starts_at: string; ends_at: string }[];
    dynamicShifts: { shift_date: string; starts_at: string; ends_at: string }[];
  }[];
  resourceTypes: {
    id: string;
    resources: { id: string; name: string; capacity: number; status: string }[];
  }[];
  services: {
    id: string;
    name: string;
    bookable: boolean;
    status: string;
    steps: SnapshotStep[];
    requires_strand_test: boolean;
    strand_test_lead_days: number;
    strand_test_duration_minutes: number;
    strand_test_preferred_weekdays: number[];
  }[];
}

function toPublishedSteps(steps: SnapshotStep[]): PublishedStep[] {
  return steps.map((step) => ({
    id: step.id,
    name: step.name,
    position: step.position,
    durationMinutes: step.duration_minutes,
    kind: step.kind,
    releasesMember: step.releases_member,
    skillRequirements: step.skillRequirements.map((requirement) => ({
      skillId: requirement.skill_id,
      quantity: requirement.quantity,
      ...(requirement.qualifier?.qualifier_option_id
        ? { qualifierOptionId: requirement.qualifier.qualifier_option_id }
        : {}),
      ...(requirement.qualifier?.custom_value
        ? { qualifierCustomValue: requirement.qualifier.custom_value }
        : {}),
    })),
    resourceRequirements: step.resourceRequirements.map((requirement) => ({
      resourceTypeId: requirement.resource_type_id,
      quantity: requirement.quantity,
      retainUntilServiceEnd: requirement.retain_until_service_end,
    })),
  }));
}

function toWeeklyHours(entries: { weekday: number; starts_at: string; ends_at: string }[]): WeeklyOperatingHours[] {
  return entries.map((entry) => ({
    weekday: entry.weekday,
    startMinuteOfDay: parseLocalTimeToMinutes(entry.starts_at),
    endMinuteOfDay: parseLocalTimeToMinutes(entry.ends_at),
  }));
}

function toWeeklyLimits(entries: { weekday: number; latest_end_time: string }[]): WeeklyServiceLimit[] {
  return entries.map((entry) => ({
    weekday: entry.weekday,
    latestEndMinuteOfDay: parseLocalTimeToMinutes(entry.latest_end_time),
  }));
}

function toDynamicShifts(entries: { shift_date: string; starts_at: string; ends_at: string }[]): DynamicShift[] {
  return entries.map((entry) => ({
    shiftDateIso: entry.shift_date,
    startMinuteOfDay: parseLocalTimeToMinutes(entry.starts_at),
    endMinuteOfDay: parseLocalTimeToMinutes(entry.ends_at),
  }));
}

function onlyDigits(value: string): string {
  return value.replace(/\D/g, '');
}

// Exceção de horário por cliente: soma ao expediente normal (nunca
// substitui) só para quem a busca identificar — por telefone (normalizado,
// prioridade) ou, na falta dele, pelo nome exato (case/espaço-insensível).
// Quem busca sem identificar a cliente não vê nenhuma exceção.
function matchClientExceptions(
  exceptions: Snapshot['clientExceptions'],
  clientPhoneDigits: string | null,
  clientName: string | null
): Snapshot['clientExceptions'] {
  if (clientPhoneDigits) {
    const normalizedPhone = onlyDigits(clientPhoneDigits);
    const byPhone = exceptions.filter(
      (entry) => entry.client_phone_digits && onlyDigits(entry.client_phone_digits) === normalizedPhone
    );
    if (byPhone.length > 0) return byPhone;
  }
  if (clientName) {
    const normalizedName = clientName.trim().toLowerCase();
    return exceptions.filter((entry) => entry.client_name.trim().toLowerCase() === normalizedName);
  }
  return [];
}

// Fixa: só turnos semanais recorrentes (member.availability).
// Dinâmica: sem padrão recorrente — só entra na busca se tiver turnos
// marcados para datas específicas (member.dynamicShifts), preenchidos hoje
// à mão no calendário do módulo Equipe. Sem nenhum turno marcado, a pessoa
// dinâmica fica de fora da busca (bloqueio conservador, igual ao que já
// valia antes de existir essa fonte — BT-106).
// Híbrida: as duas fontes juntas — é literalmente "mistura fixo e
// combinado". Compartilhada entre searchSlots e o agendamento automático
// do teste de mechas — mesma regra de disponibilidade nos dois casos.
function buildEligibleMembers(
  snapshot: Snapshot,
  utcOffsetMinutes: number,
  searchWindow: AbsoluteWindow
): EligibleMember[] {
  return snapshot.teamMembers
    .filter((member) => member.status === 'ACTIVE')
    .map((member) => {
      const weeklyWindows =
        member.availability_mode === 'DYNAMIC'
          ? []
          : resolveOperatingWindows({
              utcOffsetMinutes,
              searchWindow,
              operatingHours: toWeeklyHours(member.availability),
            });
      const dynamicWindows =
        member.availability_mode === 'FIXED'
          ? []
          : resolveDynamicShiftWindows({
              utcOffsetMinutes,
              searchWindow,
              shifts: toDynamicShifts(member.dynamicShifts),
            });

      return {
        id: member.id,
        skillIds: member.skillIds,
        skillQualifierCoverage: member.skillQualifiers.map((q) => ({
          skillId: q.skill_id,
          ...(q.qualifier_option_id ? { qualifierOptionId: q.qualifier_option_id } : {}),
          ...(q.custom_value ? { customValue: q.custom_value } : {}),
        })),
        availableWindows: [...weeklyWindows, ...dynamicWindows].sort((left, right) => left.startMs - right.startMs),
      };
    });
}

async function callRpc(
  supabaseUrl: string,
  serviceRoleKey: string,
  functionName: string,
  body: Record<string, unknown>
): Promise<{ ok: true; data: unknown } | { ok: false; status: number; error: string; code: string | null }> {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${functionName}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      authorization: `Bearer ${serviceRoleKey}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const failure = (await response.json().catch(() => ({}))) as { code?: string; message?: string };
    const status =
      failure.code === '42501'
        ? 403
        : failure.code === '40001'
          ? 409
          : failure.code === '23514' || failure.code === '22023'
            ? 422
            : failure.code === '55000' || failure.code === 'P0002'
              ? 409
              : response.status >= 400 && response.status < 500
                ? response.status
                : 502;
    return { ok: false, status, error: failure.message ?? 'DATABASE_REQUEST_FAILED', code: failure.code ?? null };
  }

  // RPCs que RETURNS void (ex.: schedule_cancel_hold, schedule_cancel_appointment)
  // vêm com corpo vazio (204 ou 200 sem conteúdo) — response.json() estoura
  // nesse caso. Bug real encontrado em teste: cancelAppointment quebrava com
  // 500 sempre que era chamado, porque isso nunca tinha sido exercitado.
  const rawBody = await response.text();
  return { ok: true, data: rawBody ? JSON.parse(rawBody) : null };
}

type RpcResult = { ok: true; data: unknown } | { ok: false; status: number; error: string; code: string | null };
type RpcCaller = (name: string, body: Record<string, unknown>) => Promise<RpcResult>;
type StrandTestResult =
  | { scheduled: true; startsAt: string; endsAt: string; memberName: string }
  | { scheduled: false; reason: string };

/**
 * Melhor esforço: tenta achar e reservar automaticamente um horário de
 * teste de mechas para o serviço recém-confirmado, se ele exigir. Nunca
 * lança — qualquer motivo de falha vira `{ scheduled: false, reason }`.
 * Devolve `null` quando o serviço nem exige teste (não aparece na resposta).
 *
 * Regras (decididas com a Duda em 2026-08-11):
 * - qualquer profissional com a competência serve, não precisa ser quem fez
 *   o atendimento principal;
 * - não bloqueia nada: se não achar horário, o agendamento principal já foi
 *   confirmado e continua confirmado — só avisa que o teste não foi
 *   marcado sozinho;
 * - ocupa uma cadeira (recurso), igual um mini-atendimento — mas em uma
 *   tabela separada (app.strand_test_bookings) que a busca normal
 *   (searchSlots) nunca enxerga, então um atendimento de verdade ainda pode
 *   cair em cima do horário do teste depois.
 */
async function tryAutoScheduleStrandTest(
  rpc: RpcCaller,
  userEmail: string,
  tenantId: string,
  confirmed: { appointmentId: string; unitId: string; serviceId: string; startsAt: string; endsAt: string }
): Promise<StrandTestResult | null> {
  const configResult = await rpc('schedule_get_active_configuration', {
    target_site_project_id: SITE_PROJECT_ID,
    target_email: userEmail,
    target_tenant_id: tenantId,
    target_unit_id: confirmed.unitId,
  });
  if (!configResult.ok) return { scheduled: false, reason: 'CONFIG_UNAVAILABLE' };

  const config = configResult.data as { timezone: string; snapshot: Snapshot };
  const service = config.snapshot.services.find((entry) => entry.id === confirmed.serviceId);
  if (!service || !service.requires_strand_test) return null;

  // Simplificação deliberada: pega a primeira competência/tipo de recurso
  // exigido entre as etapas ativas do serviço, em vez de pedir pra Duda
  // escolher de novo — na prática, serviços de coloração têm uma
  // competência principal (ex.: "Coloração") e um recurso (ex.: "Cadeira").
  const activeSteps = service.steps.filter((step) => step.kind === 'ACTIVE');
  const candidateSkillId = activeSteps.flatMap((step) => step.skillRequirements)[0]?.skill_id;
  if (!candidateSkillId) return { scheduled: false, reason: 'NO_QUALIFYING_SKILL' };
  const candidateResourceTypeId = activeSteps.flatMap((step) => step.resourceRequirements)[0]?.resource_type_id;

  const mainAppointmentStartMs = Date.parse(confirmed.startsAt);
  const strandWindow = resolveStrandTestWindow({
    mainAppointmentStartMs,
    config: {
      leadDays: service.strand_test_lead_days,
      durationMinutes: service.strand_test_duration_minutes,
      preferredWeekdays: service.strand_test_preferred_weekdays,
    },
  });
  if (strandWindow.searchWindow.endMs <= Date.now()) {
    return { scheduled: false, reason: 'WINDOW_IN_PAST' };
  }

  const utcOffsetMinutes = resolveUtcOffsetMinutes(config.timezone, new Date(strandWindow.searchWindow.startMs));
  const operatingWindows = resolveOperatingWindows({
    utcOffsetMinutes,
    searchWindow: strandWindow.searchWindow,
    operatingHours: toWeeklyHours(config.snapshot.operatingHours),
  });

  let compiledPlan;
  try {
    compiledPlan = compileServiceTimeline([
      {
        id: 'strand-test',
        name: 'Teste de mechas',
        position: 1,
        durationMinutes: strandWindow.durationMinutes,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: candidateSkillId, quantity: 1 }],
        resourceRequirements: candidateResourceTypeId
          ? [{ resourceTypeId: candidateResourceTypeId, quantity: 1, retainUntilServiceEnd: false }]
          : [],
      },
    ]);
  } catch {
    return { scheduled: false, reason: 'INVALID_STEP_CONFIG' };
  }

  const members = buildEligibleMembers(config.snapshot, utcOffsetMinutes, strandWindow.searchWindow);
  const resources: EligibleResource[] = config.snapshot.resourceTypes.flatMap((resourceType) =>
    resourceType.resources
      .filter((resource) => resource.status === 'ACTIVE')
      .map((resource) => ({ id: resource.id, resourceTypeId: resourceType.id, capacity: resource.capacity }))
  );

  // Duas fontes de ocupação, as duas só leitura: os compromissos REAIS da
  // colorista (não marcar teste em cima de um atendimento real) e outros
  // testes de mechas já marcados (não marcar dois testes em cima um do
  // outro). Nenhuma delas é escrita aqui — só schedule_record_strand_test_booking grava.
  const [realOccupanciesResult, strandOccupanciesResult] = await Promise.all([
    rpc('schedule_list_occupancies', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_unit_id: confirmed.unitId,
    }),
    rpc('schedule_list_strand_test_occupancies', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_unit_id: confirmed.unitId,
    }),
  ]);
  if (!realOccupanciesResult.ok || !strandOccupanciesResult.ok) {
    return { scheduled: false, reason: 'OCCUPANCIES_UNAVAILABLE' };
  }
  const realOccupancies = realOccupanciesResult.data as {
    memberOccupancies: { memberId: string; startMs: number; endMs: number }[];
    resourceOccupancies: { resourceId: string; startMs: number; endMs: number }[];
  };
  const strandOccupancies = strandOccupanciesResult.data as {
    memberOccupancies: { memberId: string; startMs: number; endMs: number }[];
    resourceOccupancies: { resourceId: string; startMs: number; endMs: number }[];
  };

  const toRanges = (entries: { memberId?: string; resourceId?: string; startMs: number; endMs: number }[]) =>
    entries.map((entry) => ({
      subjectId: (entry.memberId ?? entry.resourceId) as string,
      startMs: entry.startMs,
      endMs: entry.endMs,
    }));

  const searchResult = findAvailableSlots({
    referenceNowMs: Date.now(),
    operatingWindows,
    compiledPlan,
    candidateGranularityMinutes: 15,
    members,
    resources,
    existingMemberOccupancies: [
      ...toRanges(realOccupancies.memberOccupancies),
      ...toRanges(strandOccupancies.memberOccupancies),
    ],
    existingResourceOccupancies: [
      ...toRanges(realOccupancies.resourceOccupancies),
      ...toRanges(strandOccupancies.resourceOccupancies),
    ],
    maxCandidates: 1,
  });

  if (searchResult.candidates.length === 0) {
    return { scheduled: false, reason: 'NO_SLOT_FOUND' };
  }

  const candidate = searchResult.candidates[0];
  const step = candidate.steps[0];
  const memberId = step.memberId;
  if (!memberId) return { scheduled: false, reason: 'NO_SLOT_FOUND' };
  const memberName = config.snapshot.teamMembers.find((member) => member.id === memberId)?.name ?? 'Profissional';
  const resourceId = step.resourceAssignments[0]?.resourceId ?? null;

  const recordResult = await rpc('schedule_record_strand_test_booking', {
    target_site_project_id: SITE_PROJECT_ID,
    target_email: userEmail,
    target_tenant_id: tenantId,
    target_unit_id: confirmed.unitId,
    target_main_appointment_id: confirmed.appointmentId,
    target_member_id: memberId,
    target_member_name: memberName,
    target_resource_id: resourceId,
    target_starts_at: new Date(candidate.startMs).toISOString(),
    target_ends_at: new Date(candidate.endMs).toISOString(),
    target_correlation_id: crypto.randomUUID(),
  });
  if (!recordResult.ok) return { scheduled: false, reason: 'BOOKING_FAILED' };

  // A RPC devolve o que está DE FATO gravado — numa chamada repetida pro
  // mesmo agendamento principal (retry idempotente), isso é a reserva
  // original, não o candidato que acabamos de recalcular agora (que pode
  // ser um horário diferente, já que os testes anteriores agora contam
  // como ocupação). Nunca confiar em `candidate` para o valor devolvido.
  const recorded = recordResult.data as {
    scheduled: boolean;
    reason?: string;
    startsAt?: string;
    endsAt?: string;
    memberName?: string;
  };
  if (!recorded.scheduled || !recorded.startsAt || !recorded.endsAt) {
    return { scheduled: false, reason: recorded.reason ?? 'STRAND_TEST_SLOT_TAKEN' };
  }

  return {
    scheduled: true,
    startsAt: recorded.startsAt,
    endsAt: recorded.endsAt,
    memberName: recorded.memberName ?? memberName,
  };
}

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') {
    return json(405, { error: 'METHOD_NOT_ALLOWED' });
  }

  // Duas identidades chegam aqui, e nunca pela mesma porta.
  //
  // Pessoa: o e-mail vem assinado no JWT que o Supabase já verificou.
  //
  // Agente: não tem e-mail nenhum (roda como worker), então se apresenta com o
  // token que vive no Vault e recebe a identidade de serviço. E a recíproca é
  // trancada: um JWT de pessoa que diga ser agente@sistema.interno é recusado.
  // Sem essa segunda metade, bastaria alguém conseguir um token com esse e-mail
  // para virar o agente — e o crachá do agente é o que abre a agenda.
  const workerToken = request.headers.get('x-worker-token');
  const jwtEmail = emailFromVerifiedJwt(request.headers.get('authorization'));

  let userEmail: string | null = jwtEmail;

  if (workerToken) {
    const supabaseUrlForAuth = Deno.env.get('SUPABASE_URL') ?? '';
    const serviceKeyForAuth = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const check = await callRpc(supabaseUrlForAuth, serviceKeyForAuth, 'verify_worker_token', {
      p_token: workerToken,
    });
    if (!check.ok || check.data !== true) {
      return json(401, { error: 'WORKER_TOKEN_INVALID' });
    }
    userEmail = AGENT_IDENTITY_EMAIL;
  } else if (jwtEmail === AGENT_IDENTITY_EMAIL) {
    return json(403, { error: 'AGENT_IDENTITY_REQUIRES_WORKER_TOKEN' });
  }

  if (!userEmail) {
    return json(401, { error: 'UNAUTHENTICATED' });
  }

  const contentLength = Number(request.headers.get('content-length') ?? '0');
  if (contentLength > 262_144) {
    return json(413, { error: 'PAYLOAD_TOO_LARGE' });
  }

  let input: Record<string, unknown>;
  try {
    input = await request.json();
  } catch {
    return json(400, { error: 'INVALID_JSON' });
  }

  const action = input.action;
  const tenantId = input.tenantId;
  const unitId = input.unitId;

  if (typeof action !== 'string' || typeof tenantId !== 'string' || typeof unitId !== 'string') {
    return json(400, { error: 'INVALID_REQUEST' });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !serviceRoleKey) {
    return json(503, { error: 'SERVICE_NOT_CONFIGURED' });
  }

  const rpc = (name: string, body: Record<string, unknown>) => callRpc(supabaseUrl, serviceRoleKey, name, body);

  if (action === 'listBookableServices') {
    const configResult = await rpc('schedule_get_active_configuration', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_unit_id: unitId,
    });
    if (!configResult.ok) return json(configResult.status, { error: configResult.error, code: configResult.code });

    const config = configResult.data as { configurationVersionId: string; snapshot: Snapshot };
    const services = config.snapshot.services
      .filter((service) => service.bookable && service.status === 'ACTIVE' && service.steps.length > 0)
      .map((service) => ({ id: service.id, name: service.name }));

    return json(200, { data: { configurationVersionId: config.configurationVersionId, services } });
  }

  if (action === 'searchSlots') {
    const serviceId = input.serviceId;
    const variationId = typeof input.variationId === 'string' ? input.variationId : null;
    const searchFromIso = input.searchFrom;
    const searchDays = Number.isInteger(input.searchDays) ? (input.searchDays as number) : 7;
    // Identifica a cliente para enxergar exceções de horário cadastradas para
    // ela (BT-15) — opcional; sem isso, a busca só vê o expediente normal.
    const clientPhoneDigits = typeof input.clientPhoneDigits === 'string' ? input.clientPhoneDigits : null;
    const clientName = typeof input.clientName === 'string' ? input.clientName : null;

    if (typeof serviceId !== 'string' || typeof searchFromIso !== 'string') {
      return json(400, { error: 'INVALID_SEARCH_REQUEST' });
    }
    if (searchDays < 1 || searchDays > 30) {
      return json(400, { error: 'INVALID_SEARCH_WINDOW' });
    }

    const configResult = await rpc('schedule_get_active_configuration', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_unit_id: unitId,
    });
    if (!configResult.ok) return json(configResult.status, { error: configResult.error, code: configResult.code });

    const config = configResult.data as { configurationVersionId: string; timezone: string; snapshot: Snapshot };
    const snapshot = config.snapshot;

    const service = snapshot.services.find((entry) => entry.id === serviceId);
    if (!service || !service.bookable || service.status !== 'ACTIVE') {
      return json(404, { error: 'SERVICE_NOT_BOOKABLE' });
    }

    let compiledPlan;
    try {
      compiledPlan = compileServiceTimeline(toPublishedSteps(service.steps));
    } catch (caught) {
      if (caught instanceof SchedulingConfigurationError) {
        return json(422, { error: caught.code });
      }
      throw caught;
    }

    const searchFromMs = Date.parse(searchFromIso);
    if (Number.isNaN(searchFromMs)) {
      return json(400, { error: 'INVALID_SEARCH_FROM' });
    }
    const searchWindow: AbsoluteWindow = {
      startMs: searchFromMs,
      endMs: searchFromMs + searchDays * 86_400_000,
    };

    const utcOffsetMinutes = resolveUtcOffsetMinutes(config.timezone, new Date(searchFromMs));

    const baseOperatingWindows = resolveOperatingWindows({
      utcOffsetMinutes,
      searchWindow,
      operatingHours: toWeeklyHours(snapshot.operatingHours),
      serviceLimits: toWeeklyLimits(snapshot.serviceLimits),
    });

    // Exceção de horário por cliente: soma janelas extras (fora do
    // expediente normal, sem o teto de unit_service_limits) só quando a
    // busca identificou a cliente e ela tem exceção cadastrada.
    const matchedExceptions = matchClientExceptions(snapshot.clientExceptions, clientPhoneDigits, clientName);
    const exceptionWindows =
      matchedExceptions.length === 0
        ? []
        : resolveOperatingWindows({
            utcOffsetMinutes,
            searchWindow,
            operatingHours: toWeeklyHours(matchedExceptions),
          });

    const operatingWindows = [...baseOperatingWindows, ...exceptionWindows].sort(
      (left, right) => left.startMs - right.startMs
    );

    const members = buildEligibleMembers(snapshot, utcOffsetMinutes, searchWindow);

    const resourceCapacityById = new Map<string, number>();
    const resources: EligibleResource[] = snapshot.resourceTypes.flatMap((resourceType) =>
      resourceType.resources
        .filter((resource) => resource.status === 'ACTIVE')
        .map((resource) => {
          resourceCapacityById.set(resource.id, resource.capacity);
          return { id: resource.id, resourceTypeId: resourceType.id, capacity: resource.capacity };
        })
    );

    const occupanciesResult = await rpc('schedule_list_occupancies', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_unit_id: unitId,
    });
    if (!occupanciesResult.ok) {
      return json(occupanciesResult.status, { error: occupanciesResult.error, code: occupanciesResult.code });
    }
    const occupancies = occupanciesResult.data as {
      memberOccupancies: { memberId: string; startMs: number; endMs: number }[];
      resourceOccupancies: { resourceId: string; startMs: number; endMs: number }[];
    };

    // Compromissos do Google/Outlook: bloqueiam a agenda inteira da
    // unidade (não existe ainda escolha de "essa conexão é de qual
    // profissional" na tela de conectar). Falha em buscar isso não pode
    // travar a busca de horário — se o Google estiver fora do ar, o
    // motor só ignora o bloqueio extra dessa vez.
    const calendarShiftsResult = await rpc('schedule_list_calendar_shifts', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_unit_id: unitId,
    });
    const calendarShifts = calendarShiftsResult.ok
      ? (calendarShiftsResult.data as { startMs: number; endMs: number }[])
      : [];

    const existingMemberOccupancies: OccupancyRange[] = [
      ...occupancies.memberOccupancies.map((entry) => ({
        subjectId: entry.memberId,
        startMs: entry.startMs,
        endMs: entry.endMs,
      })),
      ...calendarShifts.flatMap((shift) =>
        members.map((member) => ({ subjectId: member.id, startMs: shift.startMs, endMs: shift.endMs }))
      ),
    ];
    const existingResourceOccupancies: OccupancyRange[] = occupancies.resourceOccupancies.map((entry) => ({
      subjectId: entry.resourceId,
      startMs: entry.startMs,
      endMs: entry.endMs,
    }));

    const searchResult = findAvailableSlots({
      referenceNowMs: Date.now(),
      operatingWindows,
      compiledPlan,
      candidateGranularityMinutes: 15,
      members,
      resources,
      existingMemberOccupancies,
      existingResourceOccupancies,
      maxCandidates: 8,
    });

    // Embute a capacidade de cada recurso no plano devolvido — quem cria o
    // hold (schedule_create_hold) precisa dela para escolher a vaga física
    // sem reconsultar app.resources (que é do rascunho, não da versão publicada).
    const candidates = searchResult.candidates.map((candidate: CandidateSlot) => ({
      startMs: candidate.startMs,
      endMs: candidate.endMs,
      steps: candidate.steps.map((step) => ({
        stepId: step.stepId,
        name: step.name,
        startMs: step.startMs,
        endMs: step.endMs,
        memberId: step.memberId,
        resourceAssignments: step.resourceAssignments.map((assignment) => ({
          resourceId: assignment.resourceId,
          quantity: assignment.quantity,
          capacity: resourceCapacityById.get(assignment.resourceId) ?? assignment.quantity,
        })),
      })),
    }));

    return json(200, {
      data: {
        configurationVersionId: config.configurationVersionId,
        serviceId,
        variationId,
        candidates,
        rejectionCounts: searchResult.rejectionCounts,
        attemptsMade: searchResult.attemptsMade,
        clientExceptionApplied: matchedExceptions.length > 0,
      },
    });
  }

  if (action === 'createHold') {
    const { configurationVersionId, serviceId, variationId, startsAt, endsAt, plan, idempotencyKey } = input as Record<
      string,
      unknown
    >;
    if (
      typeof configurationVersionId !== 'string' ||
      typeof serviceId !== 'string' ||
      typeof startsAt !== 'string' ||
      typeof endsAt !== 'string' ||
      typeof plan !== 'object' ||
      plan === null ||
      typeof idempotencyKey !== 'string'
    ) {
      return json(400, { error: 'INVALID_HOLD_REQUEST' });
    }

    const result = await rpc('schedule_create_hold', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_unit_id: unitId,
      target_configuration_version_id: configurationVersionId,
      target_service_id: serviceId,
      target_variation_id: typeof variationId === 'string' ? variationId : null,
      target_starts_at: startsAt,
      target_ends_at: endsAt,
      target_plan: plan,
      target_idempotency_key: idempotencyKey,
      target_correlation_id: crypto.randomUUID(),
      hold_ttl_seconds: 600,
    });
    if (!result.ok) return json(result.status, { error: result.error, code: result.code });
    return json(200, { data: result.data });
  }

  if (action === 'confirmHold') {
    const { holdId, customerLabel } = input as Record<string, unknown>;
    if (typeof holdId !== 'string') {
      return json(400, { error: 'INVALID_CONFIRM_REQUEST' });
    }

    const result = await rpc('schedule_confirm_hold', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_hold_id: holdId,
      target_correlation_id: crypto.randomUUID(),
      target_customer_label: typeof customerLabel === 'string' ? customerLabel : null,
      target_channel_connection_id: null,
      target_external_contact_ref: null,
    });
    if (!result.ok) return json(result.status, { error: result.error, code: result.code });

    const confirmed = result.data as {
      appointmentId: string;
      status: string;
      unitId: string;
      serviceId: string;
      startsAt: string;
      endsAt: string;
    };

    // Teste de mechas: melhor esforço, NUNCA derruba a confirmação do
    // agendamento principal — qualquer falha aqui (config ausente, sem
    // profissional qualificado, sem horário livre, corrida perdida) vira só
    // um `strandTest.scheduled: false`, nunca um erro pra quem chamou.
    const strandTest = await tryAutoScheduleStrandTest(rpc, userEmail, tenantId, confirmed).catch(() => null);

    return json(200, { data: { ...confirmed, ...(strandTest ? { strandTest } : {}) } });
  }

  if (action === 'cancelHold') {
    const { holdId } = input as Record<string, unknown>;
    if (typeof holdId !== 'string') {
      return json(400, { error: 'INVALID_CANCEL_REQUEST' });
    }

    const result = await rpc('schedule_cancel_hold', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_hold_id: holdId,
      target_correlation_id: crypto.randomUUID(),
    });
    if (!result.ok) return json(result.status, { error: result.error, code: result.code });
    return json(200, { data: { ok: true } });
  }

  if (action === 'cancelAppointment') {
    const { appointmentId } = input as Record<string, unknown>;
    if (typeof appointmentId !== 'string') {
      return json(400, { error: 'INVALID_CANCEL_REQUEST' });
    }

    const result = await rpc('schedule_cancel_appointment', {
      target_site_project_id: SITE_PROJECT_ID,
      target_email: userEmail,
      target_tenant_id: tenantId,
      target_appointment_id: appointmentId,
      target_correlation_id: crypto.randomUUID(),
    });
    if (!result.ok) return json(result.status, { error: result.error, code: result.code });
    return json(200, { data: { ok: true } });
  }

  return json(400, { error: 'INVALID_ACTION' });
});
