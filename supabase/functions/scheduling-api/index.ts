import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import {
  compileServiceTimeline,
  findAvailableSlots,
  resolveDynamicShiftWindows,
  resolveOperatingWindows,
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

  return { ok: true, data: await response.json() };
}

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') {
    return json(405, { error: 'METHOD_NOT_ALLOWED' });
  }

  const userEmail = emailFromVerifiedJwt(request.headers.get('authorization'));
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

    // Fixa: só turnos semanais recorrentes (member.availability).
    // Dinâmica: sem padrão recorrente — só entra na busca se tiver turnos
    // marcados para datas específicas (member.dynamicShifts), preenchidos
    // hoje à mão no calendário do módulo Equipe. Sem nenhum turno marcado,
    // a pessoa dinâmica fica de fora da busca (bloqueio conservador, igual
    // ao que já valia antes de existir essa fonte — BT-106).
    // Híbrida: as duas fontes juntas — é literalmente "mistura fixo e
    // combinado".
    const members: EligibleMember[] = snapshot.teamMembers
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

    const existingMemberOccupancies: OccupancyRange[] = occupancies.memberOccupancies.map((entry) => ({
      subjectId: entry.memberId,
      startMs: entry.startMs,
      endMs: entry.endMs,
    }));
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
    return json(200, { data: result.data });
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
