import { describe, expect, it } from 'vitest';

import { compileServiceTimeline, SchedulingConfigurationError } from './index.js';

describe('compileServiceTimeline', () => {
  it('compiles simple and compound services through the same function', () => {
    const simple = compileServiceTimeline([
      {
        id: 'nails',
        name: 'Unhas',
        sequence: 1,
        durationMinutes: 60,
        kind: 'ACTIVE',
        requiredMemberSkillIds: ['manicure'],
        requiredResourceTypeIds: ['table'],
      },
    ]);

    const compound = compileServiceTimeline([
      {
        id: 'wash',
        name: 'Lavagem',
        sequence: 1,
        durationMinutes: 20,
        kind: 'ACTIVE',
        requiredMemberSkillIds: ['hair'],
        requiredResourceTypeIds: ['washbasin'],
      },
      {
        id: 'pause',
        name: 'Pausa',
        sequence: 2,
        durationMinutes: 60,
        kind: 'PASSIVE',
        requiredMemberSkillIds: [],
        requiredResourceTypeIds: ['chair'],
      },
      {
        id: 'finish',
        name: 'Finalização',
        sequence: 3,
        durationMinutes: 115,
        kind: 'ACTIVE',
        requiredMemberSkillIds: ['hair'],
        requiredResourceTypeIds: ['chair'],
      },
    ]);

    expect(simple.durationMinutes).toBe(60);
    expect(compound.durationMinutes).toBe(195);
    expect(compound.steps[1]).toMatchObject({ occupiesMember: false, occupiesResource: true });
  });

  it('rejects duplicated sequence numbers', () => {
    expect(() =>
      compileServiceTimeline([
        {
          id: 'one',
          name: 'One',
          sequence: 1,
          durationMinutes: 10,
          kind: 'ACTIVE',
          requiredMemberSkillIds: [],
          requiredResourceTypeIds: [],
        },
        {
          id: 'two',
          name: 'Two',
          sequence: 1,
          durationMinutes: 10,
          kind: 'ACTIVE',
          requiredMemberSkillIds: [],
          requiredResourceTypeIds: [],
        },
      ])
    ).toThrowError(new SchedulingConfigurationError('STEP_SEQUENCE_DUPLICATED'));
  });
});
