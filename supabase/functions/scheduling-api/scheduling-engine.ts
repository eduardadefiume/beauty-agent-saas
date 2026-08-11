/**
 * CÓPIA SINCRONIZADA MANUALMENTE de packages/scheduling-engine/src/index.ts.
 *
 * Edge Functions deste projeto são publicadas como arquivos autocontidos
 * (deploy_edge_function envia os arquivos direto, sem passar pelo bundler
 * pnpm/Turborepo do monorepo), então um import cross-package não funciona
 * em runtime Deno aqui. Até existir um passo de build que empacote
 * @beauty/scheduling-engine para as functions, esta cópia precisa ser
 * atualizada manualmente sempre que o pacote original mudar. Os testes
 * (vitest) continuam rodando só contra o pacote original, não esta cópia.
 *
 * ---
 *
 * Motor determinístico de agenda — pacote puro.
 *
 * Regras de pureza (docs/canonical/arquitetura-tecnica-piloto-v1.md, seção 13.3):
 * - não acessa rede nem banco;
 * - não lê horário global diretamente (recebe `referenceNowMs` por parâmetro);
 * - não chama LLM;
 * - recebe todas as entradas por parâmetro, já resolvidas para instantes UTC;
 * - produz o mesmo resultado para a mesma entrada;
 * - retorna códigos de rejeição, não texto livre.
 *
 * Interpretação de fuso horário (weekday/hora local -> instante UTC) é uma etapa
 * SEPARADA (`resolveOperatingWindows`), também pura, para que o motor de busca em
 * si trabalhe só com intervalos absolutos. `resolveOperatingWindows` recebe um
 * único `utcOffsetMinutes` para toda a janela de busca — quem chama (Edge
 * Function, com acesso a `Intl`/ICU) resolve esse offset a partir do
 * `timezone` IANA da unidade para a data em questão. Isso cobre corretamente
 * fusos com horário de verão SE a janela de busca não atravessar uma
 * transição de DST; para o piloto (Brasil, offset fixo o ano todo) isso nunca
 * é um problema. Se um fuso com DST e janelas longas entrar em cena, este
 * parâmetro precisará virar um resolvedor por data — não implementado ainda
 * porque não existe essa necessidade real hoje.
 */

// ---------------------------------------------------------------------------
// Compilação da linha do tempo do serviço (etapas -> deslocamentos relativos)
// ---------------------------------------------------------------------------

export type StepKind = 'ACTIVE' | 'PASSIVE';

export interface StepSkillRequirement {
  readonly skillId: string;
  readonly quantity: number;
  /**
   * Qual variação da competência esta etapa exige (ex.: skill "Coloração",
   * opção "Vermelho") — ausentes os dois quando a competência não tem
   * qualificador. No máximo um dos dois deve vir preenchido.
   */
  readonly qualifierOptionId?: string;
  readonly qualifierCustomValue?: string;
}

export interface StepResourceRequirement {
  readonly resourceTypeId: string;
  readonly quantity: number;
  readonly retainUntilServiceEnd: boolean;
}

export interface PublishedStep {
  readonly id: string;
  readonly name: string;
  readonly position: number;
  readonly durationMinutes: number;
  readonly kind: StepKind;
  /** Só pode ser true quando `kind === 'PASSIVE'` (mesma regra do banco). */
  readonly releasesMember: boolean;
  readonly skillRequirements: readonly StepSkillRequirement[];
  readonly resourceRequirements: readonly StepResourceRequirement[];
}

export interface RelativeStepPlan {
  readonly stepId: string;
  readonly name: string;
  readonly position: number;
  readonly startsAfterMinutes: number;
  readonly endsAfterMinutes: number;
  readonly kind: StepKind;
  readonly occupiesMember: boolean;
  readonly skillRequirements: readonly StepSkillRequirement[];
  readonly resourceRequirements: readonly StepResourceRequirement[];
}

export interface CompiledServicePlan {
  readonly durationMinutes: number;
  readonly steps: readonly RelativeStepPlan[];
}

export type CompileFailureCode =
  | 'SERVICE_HAS_NO_STEPS'
  | 'STEP_DURATION_UNRESOLVED'
  | 'STEP_POSITION_DUPLICATED'
  | 'RELEASES_MEMBER_ON_ACTIVE_STEP';

export class SchedulingConfigurationError extends Error {
  constructor(readonly code: CompileFailureCode) {
    super(code);
    this.name = 'SchedulingConfigurationError';
  }
}

export function compileServiceTimeline(steps: readonly PublishedStep[]): CompiledServicePlan {
  if (steps.length === 0) {
    throw new SchedulingConfigurationError('SERVICE_HAS_NO_STEPS');
  }

  const ordered = [...steps].sort((left, right) => left.position - right.position);
  const positions = new Set<number>();
  let cursor = 0;

  const plan = ordered.map((step): RelativeStepPlan => {
    if (!Number.isInteger(step.durationMinutes) || step.durationMinutes <= 0) {
      throw new SchedulingConfigurationError('STEP_DURATION_UNRESOLVED');
    }
    if (positions.has(step.position)) {
      throw new SchedulingConfigurationError('STEP_POSITION_DUPLICATED');
    }
    if (step.releasesMember && step.kind !== 'PASSIVE') {
      throw new SchedulingConfigurationError('RELEASES_MEMBER_ON_ACTIVE_STEP');
    }
    positions.add(step.position);

    const startsAfterMinutes = cursor;
    cursor += step.durationMinutes;

    return {
      stepId: step.id,
      name: step.name,
      position: step.position,
      startsAfterMinutes,
      endsAfterMinutes: cursor,
      kind: step.kind,
      occupiesMember: step.skillRequirements.length > 0 && !step.releasesMember,
      skillRequirements: step.skillRequirements,
      resourceRequirements: step.resourceRequirements,
    };
  });

  return { durationMinutes: cursor, steps: plan };
}

// ---------------------------------------------------------------------------
// Etapa 1 do pipeline: resolver expediente local -> janelas absolutas (UTC ms)
// ---------------------------------------------------------------------------

export interface AbsoluteWindow {
  readonly startMs: number;
  readonly endMs: number;
}

export interface WeeklyOperatingHours {
  readonly weekday: number; // 0 (domingo) .. 6 (sábado)
  readonly startMinuteOfDay: number; // minutos desde 00:00 local
  readonly endMinuteOfDay: number;
}

export interface WeeklyServiceLimit {
  readonly weekday: number;
  readonly latestEndMinuteOfDay: number;
}

/**
 * Resolve o expediente semanal (hora local, offset fixo) em janelas absolutas
 * UTC, uma por data dentro da janela de busca, já intersectadas com o término
 * máximo do dia (`unit_service_limits`) quando houver.
 */
export function resolveOperatingWindows(input: {
  readonly utcOffsetMinutes: number;
  readonly searchWindow: AbsoluteWindow;
  readonly operatingHours: readonly WeeklyOperatingHours[];
  readonly serviceLimits?: readonly WeeklyServiceLimit[];
}): readonly AbsoluteWindow[] {
  const { utcOffsetMinutes, searchWindow, operatingHours, serviceLimits = [] } = input;
  const offsetMs = utcOffsetMinutes * 60_000;
  const windows: AbsoluteWindow[] = [];

  const dayMs = 86_400_000;
  const firstLocalMidnightUtcMs =
    Math.floor((searchWindow.startMs + offsetMs) / dayMs) * dayMs - offsetMs;

  for (let localMidnight = firstLocalMidnightUtcMs; localMidnight < searchWindow.endMs; localMidnight += dayMs) {
    const localDate = new Date(localMidnight + offsetMs);
    const weekday = localDate.getUTCDay();

    for (const hours of operatingHours) {
      if (hours.weekday !== weekday) continue;

      const limit = serviceLimits.find((entry) => entry.weekday === weekday);
      const endMinute = limit
        ? Math.min(hours.endMinuteOfDay, limit.latestEndMinuteOfDay)
        : hours.endMinuteOfDay;
      if (endMinute <= hours.startMinuteOfDay) continue;

      const startMs = localMidnight + hours.startMinuteOfDay * 60_000;
      const endMs = localMidnight + endMinute * 60_000;

      const clippedStart = Math.max(startMs, searchWindow.startMs);
      const clippedEnd = Math.min(endMs, searchWindow.endMs);
      if (clippedStart < clippedEnd) {
        windows.push({ startMs: clippedStart, endMs: clippedEnd });
      }
    }
  }

  return windows.sort((left, right) => left.startMs - right.startMs);
}

export interface DynamicShift {
  /** Data local no formato "AAAA-MM-DD" — não é um dia da semana recorrente. */
  readonly shiftDateIso: string;
  readonly startMinuteOfDay: number;
  readonly endMinuteOfDay: number;
}

/**
 * Resolve turnos de disponibilidade Dinâmica (datas específicas marcadas à
 * mão no calendário do módulo Equipe — ex.: "trabalho sábado 15/08 das 7h às
 * 18h", mas não todo sábado) em janelas absolutas UTC, clipadas à janela de
 * busca. Ao contrário de `resolveOperatingWindows`, não é um padrão semanal
 * recorrente — cada turno é uma data concreta.
 */
export function resolveDynamicShiftWindows(input: {
  readonly utcOffsetMinutes: number;
  readonly searchWindow: AbsoluteWindow;
  readonly shifts: readonly DynamicShift[];
}): readonly AbsoluteWindow[] {
  const { utcOffsetMinutes, searchWindow, shifts } = input;
  const offsetMs = utcOffsetMinutes * 60_000;
  const windows: AbsoluteWindow[] = [];

  for (const shift of shifts) {
    const localMidnightUtcMs = Date.parse(`${shift.shiftDateIso}T00:00:00Z`) - offsetMs;
    if (Number.isNaN(localMidnightUtcMs)) continue;
    if (shift.endMinuteOfDay <= shift.startMinuteOfDay) continue;

    const startMs = localMidnightUtcMs + shift.startMinuteOfDay * 60_000;
    const endMs = localMidnightUtcMs + shift.endMinuteOfDay * 60_000;

    const clippedStart = Math.max(startMs, searchWindow.startMs);
    const clippedEnd = Math.min(endMs, searchWindow.endMs);
    if (clippedStart < clippedEnd) {
      windows.push({ startMs: clippedStart, endMs: clippedEnd });
    }
  }

  return windows.sort((left, right) => left.startMs - right.startMs);
}

// ---------------------------------------------------------------------------
// Etapa 2 do pipeline: busca de candidatos com backtracking limitado
// ---------------------------------------------------------------------------

export interface OccupancyRange {
  readonly subjectId: string; // memberId ou resourceId
  readonly startMs: number;
  readonly endMs: number;
}

export interface SkillQualifierCoverage {
  readonly skillId: string;
  readonly qualifierOptionId?: string;
  readonly customValue?: string;
}

export interface EligibleMember {
  readonly id: string;
  readonly skillIds: readonly string[];
  /** Quais variações de cada competência esta pessoa cobre (ex.: Coloração -> Castanho/Preto e Vermelho). */
  readonly skillQualifierCoverage: readonly SkillQualifierCoverage[];
  /** Janelas já resolvidas para UTC (turnos fixos/híbridos do dia). Dinâmicos sem calendário confirmado não devem ser incluídos pelo chamador (bloqueio conservador, BT-106). */
  readonly availableWindows: readonly AbsoluteWindow[];
}

export interface EligibleResource {
  readonly id: string;
  readonly resourceTypeId: string;
  readonly capacity: number;
}

export type RejectionCode =
  | 'EXCEEDS_OPERATING_WINDOW'
  | 'BEFORE_REFERENCE_CLOCK'
  | 'NO_QUALIFIED_MEMBER'
  | 'MEMBER_UNAVAILABLE'
  | 'MEMBER_OCCUPIED'
  | 'NO_RESOURCE_OF_TYPE'
  | 'RESOURCE_CAPACITY_EXCEEDED';

export interface ResourceAssignment {
  readonly resourceId: string;
  readonly quantity: number;
}

export interface StepAssignment {
  readonly stepId: string;
  readonly name: string;
  readonly startMs: number;
  readonly endMs: number;
  readonly memberId: string | null;
  readonly resourceAssignments: readonly ResourceAssignment[];
}

export interface CandidateSlot {
  readonly startMs: number;
  readonly endMs: number;
  readonly steps: readonly StepAssignment[];
}

export interface FindAvailableSlotsInput {
  readonly referenceNowMs: number;
  readonly operatingWindows: readonly AbsoluteWindow[];
  readonly compiledPlan: CompiledServicePlan;
  /** Granularidade dos horários candidatos, em minutos (ex.: 15). */
  readonly candidateGranularityMinutes: number;
  /**
   * Ordem de preferência já resolvida pelo chamador (prioridade/substitutos —
   * BT-102). O motor faz first-fit respeitando essa ordem; não reordena.
   */
  readonly members: readonly EligibleMember[];
  readonly resources: readonly EligibleResource[];
  readonly existingMemberOccupancies: readonly OccupancyRange[];
  readonly existingResourceOccupancies: readonly OccupancyRange[];
  /** Máximo de candidatos válidos a retornar. Default 8. */
  readonly maxCandidates?: number;
  /** Máximo de horários de início testados antes de desistir (limita custo). Default 500. */
  readonly maxAttempts?: number;
}

export interface FindAvailableSlotsResult {
  readonly candidates: readonly CandidateSlot[];
  readonly attemptsMade: number;
  readonly rejectionCounts: Readonly<Partial<Record<RejectionCode, number>>>;
}

function overlaps(aStart: number, aEnd: number, bStart: number, bEnd: number): boolean {
  return aStart < bEnd && bStart < aEnd;
}

function isWithinAnyWindow(start: number, end: number, windows: readonly AbsoluteWindow[]): boolean {
  return windows.some((window) => start >= window.startMs && end <= window.endMs);
}

/**
 * Um membro só cobre uma exigência de competência se tiver a skill E, quando
 * a etapa exige uma variação específica (ex.: Coloração:Vermelho), cobrir
 * exatamente essa variação — ter "Coloração" sem cobrir "Vermelho" não conta.
 * É essa checagem que impede o motor de escalar alguém pra um caso que não
 * sabe fazer só porque tem a competência de forma genérica.
 */
function memberCoversSkillRequirement(member: EligibleMember, requirement: StepSkillRequirement): boolean {
  if (!member.skillIds.includes(requirement.skillId)) return false;

  const needsQualifier =
    requirement.qualifierOptionId !== undefined || requirement.qualifierCustomValue !== undefined;
  if (!needsQualifier) return true;

  return member.skillQualifierCoverage.some((coverage) => {
    if (coverage.skillId !== requirement.skillId) return false;
    if (requirement.qualifierOptionId !== undefined) {
      return coverage.qualifierOptionId === requirement.qualifierOptionId;
    }
    if (requirement.qualifierCustomValue !== undefined) {
      return (
        coverage.customValue !== undefined &&
        coverage.customValue.trim().toLowerCase() === requirement.qualifierCustomValue.trim().toLowerCase()
      );
    }
    return false;
  });
}

export function findAvailableSlots(input: FindAvailableSlotsInput): FindAvailableSlotsResult {
  const {
    referenceNowMs,
    operatingWindows,
    compiledPlan,
    candidateGranularityMinutes,
    members,
    resources,
    existingMemberOccupancies,
    existingResourceOccupancies,
    maxCandidates = 8,
    maxAttempts = 500,
  } = input;

  const granularityMs = candidateGranularityMinutes * 60_000;
  const totalDurationMs = compiledPlan.durationMinutes * 60_000;

  const candidates: CandidateSlot[] = [];
  const rejectionCounts: Partial<Record<RejectionCode, number>> = {};
  let attemptsMade = 0;

  const recordRejection = (code: RejectionCode) => {
    rejectionCounts[code] = (rejectionCounts[code] ?? 0) + 1;
  };

  for (const window of operatingWindows) {
    if (candidates.length >= maxCandidates || attemptsMade >= maxAttempts) break;

    for (
      let candidateStart = window.startMs;
      candidateStart + totalDurationMs <= window.endMs;
      candidateStart += granularityMs
    ) {
      if (candidates.length >= maxCandidates || attemptsMade >= maxAttempts) break;
      attemptsMade += 1;

      const candidateEnd = candidateStart + totalDurationMs;

      if (candidateStart < referenceNowMs) {
        recordRejection('BEFORE_REFERENCE_CLOCK');
        continue;
      }
      if (candidateEnd > window.endMs) {
        recordRejection('EXCEEDS_OPERATING_WINDOW');
        continue;
      }

      const stepAssignments: StepAssignment[] = [];
      // Ocupações provisoriamente reservadas só para ESTE candidato, para que
      // uma etapa não conflite com outra etapa do mesmo agendamento ao
      // escolher o mesmo membro/recurso (defesa extra; por construção as
      // etapas de um mesmo serviço já são sequenciais e não se sobrepõem).
      const claimedForCandidate: OccupancyRange[] = [];

      let rejection: RejectionCode | null = null;

      for (const step of compiledPlan.steps) {
        const stepStart = candidateStart + step.startsAfterMinutes * 60_000;
        const stepEnd = candidateStart + step.endsAfterMinutes * 60_000;

        let memberId: string | null = null;

        if (step.occupiesMember) {
          const qualified = members.filter((member) =>
            step.skillRequirements.every((requirement) => memberCoversSkillRequirement(member, requirement))
          );

          if (qualified.length === 0) {
            rejection = 'NO_QUALIFIED_MEMBER';
            break;
          }

          const available = qualified.find((member) => {
            if (!isWithinAnyWindow(stepStart, stepEnd, member.availableWindows)) return false;
            const busy = [...existingMemberOccupancies, ...claimedForCandidate].some(
              (occupancy) =>
                occupancy.subjectId === member.id && overlaps(stepStart, stepEnd, occupancy.startMs, occupancy.endMs)
            );
            return !busy;
          });

          if (!available) {
            const anyAvailableWindow = qualified.some((member) =>
              isWithinAnyWindow(stepStart, stepEnd, member.availableWindows)
            );
            rejection = anyAvailableWindow ? 'MEMBER_OCCUPIED' : 'MEMBER_UNAVAILABLE';
            break;
          }

          memberId = available.id;
          claimedForCandidate.push({ subjectId: available.id, startMs: stepStart, endMs: stepEnd });
        }

        const resourceAssignments: ResourceAssignment[] = [];

        for (const requirement of step.resourceRequirements) {
          const rangeEnd = requirement.retainUntilServiceEnd ? candidateEnd : stepEnd;
          const candidatesOfType = resources.filter((resource) => resource.resourceTypeId === requirement.resourceTypeId);

          if (candidatesOfType.length === 0) {
            rejection = 'NO_RESOURCE_OF_TYPE';
            break;
          }

          const fitting = candidatesOfType.find((resource) => {
            const concurrentUsage = [...existingResourceOccupancies, ...claimedForCandidate].filter(
              (occupancy) =>
                occupancy.subjectId === resource.id && overlaps(stepStart, rangeEnd, occupancy.startMs, occupancy.endMs)
            ).length;
            return resource.capacity - concurrentUsage >= requirement.quantity;
          });

          if (!fitting) {
            rejection = 'RESOURCE_CAPACITY_EXCEEDED';
            break;
          }

          resourceAssignments.push({ resourceId: fitting.id, quantity: requirement.quantity });
          for (let unit = 0; unit < requirement.quantity; unit += 1) {
            claimedForCandidate.push({ subjectId: fitting.id, startMs: stepStart, endMs: rangeEnd });
          }
        }

        if (rejection) break;

        stepAssignments.push({
          stepId: step.stepId,
          name: step.name,
          startMs: stepStart,
          endMs: stepEnd,
          memberId,
          resourceAssignments,
        });
      }

      if (rejection) {
        recordRejection(rejection);
        continue;
      }

      candidates.push({ startMs: candidateStart, endMs: candidateEnd, steps: stepAssignments });
    }
  }

  return { candidates, attemptsMade, rejectionCounts };
}

// ---------------------------------------------------------------------------
// Teste de mechas (strand test) — cálculo da janela, não o agendamento
// ---------------------------------------------------------------------------

export interface StrandTestConfig {
  /** Quantos dias antes do atendimento principal a janela de busca abre. */
  readonly leadDays: number;
  readonly durationMinutes: number;
  /** Dias da semana preferidos para o teste (ex.: [4, 5] = quinta/sexta). */
  readonly preferredWeekdays: readonly number[];
}

export interface StrandTestWindow {
  readonly searchWindow: AbsoluteWindow;
  readonly preferredWeekdays: readonly number[];
  readonly durationMinutes: number;
}

/**
 * Calcula SÓ a janela de busca do teste de mechas a partir do horário do
 * atendimento principal — de `leadDays` dias antes até a véspera dele (não
 * inclui o próprio dia do atendimento). Ex.: atendimento marcado para um
 * sábado com leadDays=7 -> janela do sábado anterior até a sexta-feira
 * antes do atendimento.
 *
 * Não agenda nada sozinho: quem chama ainda precisa rodar uma busca
 * separada (`findAvailableSlots`, com o serviço/etapa do teste) dentro
 * dessa janela — essa função só resolve "onde procurar", não "o que
 * escolher". `preferredWeekdays` fica disponível para quem for ordenar os
 * candidatos encontrados (priorizar quinta/sexta, por exemplo), mas o motor
 * de busca em si não prioriza dia da semana hoje.
 */
export function resolveStrandTestWindow(input: {
  readonly mainAppointmentStartMs: number;
  readonly config: StrandTestConfig;
}): StrandTestWindow {
  const { mainAppointmentStartMs, config } = input;
  const dayMs = 86_400_000;

  return {
    searchWindow: {
      startMs: mainAppointmentStartMs - config.leadDays * dayMs,
      endMs: mainAppointmentStartMs - dayMs,
    },
    preferredWeekdays: config.preferredWeekdays,
    durationMinutes: config.durationMinutes,
  };
}
