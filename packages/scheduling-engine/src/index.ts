export type StepKind = 'ACTIVE' | 'PASSIVE' | 'WAITING';

export interface PublishedStep {
  readonly id: string;
  readonly name: string;
  readonly sequence: number;
  readonly durationMinutes: number;
  readonly kind: StepKind;
  readonly requiredMemberSkillIds: readonly string[];
  readonly requiredResourceTypeIds: readonly string[];
}

export interface RelativeStepPlan {
  readonly stepId: string;
  readonly name: string;
  readonly sequence: number;
  readonly startsAfterMinutes: number;
  readonly endsAfterMinutes: number;
  readonly occupiesMember: boolean;
  readonly occupiesResource: boolean;
}

export interface CompiledServicePlan {
  readonly durationMinutes: number;
  readonly steps: readonly RelativeStepPlan[];
}

export type CompileFailureCode =
  'SERVICE_HAS_NO_STEPS' | 'STEP_DURATION_UNRESOLVED' | 'STEP_SEQUENCE_DUPLICATED';

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

  const ordered = [...steps].sort((left, right) => left.sequence - right.sequence);
  const sequences = new Set<number>();
  let cursor = 0;

  const plan = ordered.map((step): RelativeStepPlan => {
    if (!Number.isInteger(step.durationMinutes) || step.durationMinutes <= 0) {
      throw new SchedulingConfigurationError('STEP_DURATION_UNRESOLVED');
    }
    if (sequences.has(step.sequence)) {
      throw new SchedulingConfigurationError('STEP_SEQUENCE_DUPLICATED');
    }
    sequences.add(step.sequence);

    const startsAfterMinutes = cursor;
    cursor += step.durationMinutes;

    return {
      stepId: step.id,
      name: step.name,
      sequence: step.sequence,
      startsAfterMinutes,
      endsAfterMinutes: cursor,
      occupiesMember: step.requiredMemberSkillIds.length > 0,
      occupiesResource: step.requiredResourceTypeIds.length > 0,
    };
  });

  return { durationMinutes: cursor, steps: plan };
}
