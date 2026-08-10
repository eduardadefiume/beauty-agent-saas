import { describe, expect, it } from 'vitest';

import {
  compileServiceTimeline,
  findAvailableSlots,
  resolveDynamicShiftWindows,
  resolveOperatingWindows,
  SchedulingConfigurationError,
  type AbsoluteWindow,
  type PublishedStep,
} from './index.js';

describe('compileServiceTimeline', () => {
  it('compiles simple and compound services through the same function', () => {
    const simple = compileServiceTimeline([
      {
        id: 'nails',
        name: 'Unhas',
        position: 1,
        durationMinutes: 60,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'manicure', quantity: 1 }],
        resourceRequirements: [{ resourceTypeId: 'table', quantity: 1, retainUntilServiceEnd: false }],
      },
    ]);

    const compound = compileServiceTimeline([
      {
        id: 'wash',
        name: 'Lavagem',
        position: 1,
        durationMinutes: 20,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [{ resourceTypeId: 'washbasin', quantity: 1, retainUntilServiceEnd: false }],
      },
      {
        id: 'pause',
        name: 'Pausa (tintura processando)',
        position: 2,
        durationMinutes: 60,
        kind: 'PASSIVE',
        releasesMember: true,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [{ resourceTypeId: 'chair', quantity: 1, retainUntilServiceEnd: false }],
      },
      {
        id: 'finish',
        name: 'Finalização',
        position: 3,
        durationMinutes: 115,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [{ resourceTypeId: 'chair', quantity: 1, retainUntilServiceEnd: false }],
      },
    ]);

    expect(simple.durationMinutes).toBe(60);
    expect(compound.durationMinutes).toBe(195);
    // Etapa PASSIVE com releasesMember=true libera o profissional mesmo tendo skill exigida.
    expect(compound.steps[1]).toMatchObject({ occupiesMember: false });
    expect(compound.steps[0]).toMatchObject({ occupiesMember: true });
  });

  it('rejects posições duplicadas', () => {
    const dup: PublishedStep[] = [
      {
        id: 'one',
        name: 'One',
        position: 1,
        durationMinutes: 10,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [],
        resourceRequirements: [],
      },
      {
        id: 'two',
        name: 'Two',
        position: 1,
        durationMinutes: 10,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [],
        resourceRequirements: [],
      },
    ];
    expect(() => compileServiceTimeline(dup)).toThrowError(
      new SchedulingConfigurationError('STEP_POSITION_DUPLICATED')
    );
  });

  it('rejeita releasesMember em etapa ACTIVE (mesma regra do banco)', () => {
    expect(() =>
      compileServiceTimeline([
        {
          id: 'one',
          name: 'One',
          position: 1,
          durationMinutes: 10,
          kind: 'ACTIVE',
          releasesMember: true,
          skillRequirements: [],
          resourceRequirements: [],
        },
      ])
    ).toThrowError(new SchedulingConfigurationError('RELEASES_MEMBER_ON_ACTIVE_STEP'));
  });
});

describe('resolveOperatingWindows', () => {
  it('resolve expediente semanal para instantes UTC com offset fixo (America/Sao_Paulo = -180min)', () => {
    // 2026-08-10 é uma segunda-feira.
    const searchWindow: AbsoluteWindow = {
      startMs: Date.parse('2026-08-10T00:00:00Z'),
      endMs: Date.parse('2026-08-13T00:00:00Z'),
    };

    const windows = resolveOperatingWindows({
      utcOffsetMinutes: -180,
      searchWindow,
      operatingHours: [
        { weekday: 1, startMinuteOfDay: 9 * 60, endMinuteOfDay: 19 * 60 }, // segunda 09:00-19:00 local
      ],
    });

    expect(windows).toHaveLength(1);
    // 09:00 -03:00 == 12:00 UTC
    expect(new Date(windows[0]!.startMs).toISOString()).toBe('2026-08-10T12:00:00.000Z');
    expect(new Date(windows[0]!.endMs).toISOString()).toBe('2026-08-10T22:00:00.000Z');
  });

  it('aplica término máximo do dia (unit_service_limits) quando mais cedo que o expediente', () => {
    const searchWindow: AbsoluteWindow = {
      startMs: Date.parse('2026-08-10T00:00:00Z'),
      endMs: Date.parse('2026-08-11T00:00:00Z'),
    };
    const windows = resolveOperatingWindows({
      utcOffsetMinutes: -180,
      searchWindow,
      operatingHours: [{ weekday: 1, startMinuteOfDay: 9 * 60, endMinuteOfDay: 19 * 60 }],
      serviceLimits: [{ weekday: 1, latestEndMinuteOfDay: 17 * 60 }],
    });

    expect(new Date(windows[0]!.endMs).toISOString()).toBe('2026-08-10T20:00:00.000Z'); // 17:00 -03:00
  });
});

describe('resolveDynamicShiftWindows', () => {
  it('resolve uma data específica marcada à mão, não um padrão semanal', () => {
    const searchWindow: AbsoluteWindow = {
      startMs: Date.parse('2026-08-01T00:00:00Z'),
      endMs: Date.parse('2026-08-31T00:00:00Z'),
    };

    const windows = resolveDynamicShiftWindows({
      utcOffsetMinutes: -180,
      searchWindow,
      shifts: [{ shiftDateIso: '2026-08-15', startMinuteOfDay: 7 * 60, endMinuteOfDay: 18 * 60 }],
    });

    expect(windows).toHaveLength(1);
    // 07:00 -03:00 == 10:00 UTC
    expect(new Date(windows[0]!.startMs).toISOString()).toBe('2026-08-15T10:00:00.000Z');
    expect(new Date(windows[0]!.endMs).toISOString()).toBe('2026-08-15T21:00:00.000Z');
  });

  it('ignora turnos fora da janela de busca e turnos com horário inválido', () => {
    const searchWindow: AbsoluteWindow = {
      startMs: Date.parse('2026-08-01T00:00:00Z'),
      endMs: Date.parse('2026-08-10T00:00:00Z'),
    };

    const windows = resolveDynamicShiftWindows({
      utcOffsetMinutes: -180,
      searchWindow,
      shifts: [
        { shiftDateIso: '2026-09-01', startMinuteOfDay: 9 * 60, endMinuteOfDay: 18 * 60 }, // fora da janela
        { shiftDateIso: '2026-08-05', startMinuteOfDay: 18 * 60, endMinuteOfDay: 9 * 60 }, // fim antes do início
      ],
    });

    expect(windows).toHaveLength(0);
  });
});

describe('findAvailableSlots', () => {
  const window: AbsoluteWindow = {
    startMs: Date.parse('2026-08-10T12:00:00Z'), // 09:00 local
    endMs: Date.parse('2026-08-10T22:00:00Z'), // 19:00 local
  };

  it('encontra um candidato simples com um profissional qualificado e disponível', () => {
    const plan = compileServiceTimeline([
      {
        id: 'step-1',
        name: 'Corte',
        position: 1,
        durationMinutes: 30,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [],
      },
    ]);

    const result = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [{ id: 'member-1', skillIds: ['hair'], skillQualifierCoverage: [], availableWindows: [window] }],
      resources: [],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [],
      maxCandidates: 3,
    });

    expect(result.candidates.length).toBeGreaterThan(0);
    expect(result.candidates[0]!.steps[0]).toMatchObject({ memberId: 'member-1' });
  });

  it('rejeita com NO_QUALIFIED_MEMBER quando ninguém tem a skill', () => {
    const plan = compileServiceTimeline([
      {
        id: 'step-1',
        name: 'Corte',
        position: 1,
        durationMinutes: 30,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [],
      },
    ]);

    const result = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [{ id: 'member-1', skillIds: ['nails'], skillQualifierCoverage: [], availableWindows: [window] }],
      resources: [],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [],
    });

    expect(result.candidates).toHaveLength(0);
    expect(result.rejectionCounts.NO_QUALIFIED_MEMBER).toBeGreaterThan(0);
  });

  it('respeita ocupação existente do membro (não oferece o mesmo horário duas vezes)', () => {
    const plan = compileServiceTimeline([
      {
        id: 'step-1',
        name: 'Corte',
        position: 1,
        durationMinutes: 30,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [],
      },
    ]);

    const busyStart = window.startMs; // primeiro horário candidato já está ocupado
    const busyEnd = busyStart + 30 * 60_000;

    const result = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [{ id: 'member-1', skillIds: ['hair'], skillQualifierCoverage: [], availableWindows: [window] }],
      resources: [],
      existingMemberOccupancies: [{ subjectId: 'member-1', startMs: busyStart, endMs: busyEnd }],
      existingResourceOccupancies: [],
      maxCandidates: 1,
    });

    expect(result.candidates).toHaveLength(1);
    expect(result.candidates[0]!.startMs).toBe(busyEnd); // pulou para o próximo horário livre
    expect(result.rejectionCounts.MEMBER_OCCUPIED).toBeGreaterThan(0);
  });

  it('respeita capacidade de recurso com múltiplas vagas físicas (BT-103)', () => {
    const plan = compileServiceTimeline([
      {
        id: 'step-1',
        name: 'Escova',
        position: 1,
        durationMinutes: 30,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [{ resourceTypeId: 'chair', quantity: 1, retainUntilServiceEnd: false }],
      },
    ]);

    const slotStart = window.startMs;
    const slotEnd = slotStart + 30 * 60_000;

    // Cadeira única com capacidade 1, já ocupada no primeiro horário.
    const result = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [
        { id: 'member-1', skillIds: ['hair'], skillQualifierCoverage: [], availableWindows: [window] },
        { id: 'member-2', skillIds: ['hair'], skillQualifierCoverage: [], availableWindows: [window] },
      ],
      resources: [{ id: 'chair-1', resourceTypeId: 'chair', capacity: 1 }],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [{ subjectId: 'chair-1', startMs: slotStart, endMs: slotEnd }],
      maxCandidates: 1,
    });

    expect(result.candidates).toHaveLength(1);
    expect(result.candidates[0]!.startMs).toBe(slotEnd);
    expect(result.rejectionCounts.RESOURCE_CAPACITY_EXCEEDED).toBeGreaterThan(0);
  });

  it('libera o profissional em etapa PASSIVE com releasesMember, mas mantém o recurso', () => {
    const plan = compileServiceTimeline([
      {
        id: 'wash',
        name: 'Lavagem',
        position: 1,
        durationMinutes: 20,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [],
      },
      {
        id: 'process',
        name: 'Processamento de tintura',
        position: 2,
        durationMinutes: 40,
        kind: 'PASSIVE',
        releasesMember: true,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [{ resourceTypeId: 'chair', quantity: 1, retainUntilServiceEnd: false }],
      },
    ]);

    const result = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 60,
      members: [{ id: 'member-1', skillIds: ['hair'], skillQualifierCoverage: [], availableWindows: [window] }],
      resources: [{ id: 'chair-1', resourceTypeId: 'chair', capacity: 1 }],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [],
      maxCandidates: 1,
    });

    expect(result.candidates).toHaveLength(1);
    const [washStep, processStep] = result.candidates[0]!.steps;
    expect(washStep).toMatchObject({ memberId: 'member-1' });
    // Etapa passiva libera o profissional: nenhum membro fica alocado a ela.
    expect(processStep).toMatchObject({ memberId: null });
    expect(processStep!.resourceAssignments).toEqual([{ resourceId: 'chair-1', quantity: 1 }]);
  });

  it('nunca oferece horário antes do relógio de referência (agora)', () => {
    const plan = compileServiceTimeline([
      {
        id: 'step-1',
        name: 'Corte',
        position: 1,
        durationMinutes: 30,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'hair', quantity: 1 }],
        resourceRequirements: [],
      },
    ]);

    const nowMs = window.startMs + 3 * 60 * 60_000; // 3h depois da abertura

    const result = findAvailableSlots({
      referenceNowMs: nowMs,
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [{ id: 'member-1', skillIds: ['hair'], skillQualifierCoverage: [], availableWindows: [window] }],
      resources: [],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [],
      maxCandidates: 1,
    });

    expect(result.candidates[0]!.startMs).toBeGreaterThanOrEqual(nowMs);
  });

  it('não escala quem tem a competência mas não cobre a variação exigida (ex.: Coloração:Vermelho)', () => {
    const plan = compileServiceTimeline([
      {
        id: 'step-1',
        name: 'Aplicação',
        position: 1,
        durationMinutes: 30,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'coloracao', quantity: 1, qualifierOptionId: 'vermelho' }],
        resourceRequirements: [],
      },
    ]);

    const onlyCastanho = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [
        {
          id: 'member-1',
          skillIds: ['coloracao'],
          skillQualifierCoverage: [{ skillId: 'coloracao', qualifierOptionId: 'castanho' }],
          availableWindows: [window],
        },
      ],
      resources: [],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [],
    });
    expect(onlyCastanho.candidates).toHaveLength(0);
    expect(onlyCastanho.rejectionCounts.NO_QUALIFIED_MEMBER).toBeGreaterThan(0);

    const coveringVermelho = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [
        {
          id: 'member-1',
          skillIds: ['coloracao'],
          skillQualifierCoverage: [
            { skillId: 'coloracao', qualifierOptionId: 'castanho' },
            { skillId: 'coloracao', qualifierOptionId: 'vermelho' },
          ],
          availableWindows: [window],
        },
      ],
      resources: [],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [],
      maxCandidates: 1,
    });
    expect(coveringVermelho.candidates).toHaveLength(1);
    expect(coveringVermelho.candidates[0]!.steps[0]).toMatchObject({ memberId: 'member-1' });
  });

  it('casa cobertura livre ("outro") por texto, sem diferenciar maiúsculas/acentuação de espaços', () => {
    const plan = compileServiceTimeline([
      {
        id: 'step-1',
        name: 'Aplicação',
        position: 1,
        durationMinutes: 30,
        kind: 'ACTIVE',
        releasesMember: false,
        skillRequirements: [{ skillId: 'coloracao', quantity: 1, qualifierCustomValue: 'Arco-íris' }],
        resourceRequirements: [],
      },
    ]);

    const result = findAvailableSlots({
      referenceNowMs: Date.parse('2026-08-10T00:00:00Z'),
      operatingWindows: [window],
      compiledPlan: plan,
      candidateGranularityMinutes: 30,
      members: [
        {
          id: 'member-1',
          skillIds: ['coloracao'],
          skillQualifierCoverage: [{ skillId: 'coloracao', customValue: '  arco-íris  ' }],
          availableWindows: [window],
        },
      ],
      resources: [],
      existingMemberOccupancies: [],
      existingResourceOccupancies: [],
      maxCandidates: 1,
    });
    expect(result.candidates).toHaveLength(1);
  });
});
