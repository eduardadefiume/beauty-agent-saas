import { describe, expect, it } from 'vitest';

import { FixedClock, SequenceIdGenerator } from './index.js';

describe('injectable domain primitives', () => {
  it('keeps time deterministic', () => {
    const clock = new FixedClock(new Date('2026-08-03T12:00:00Z'));
    expect(clock.now().toISOString()).toBe('2026-08-03T12:00:00.000Z');
  });

  it('generates deterministic test IDs', () => {
    const ids = new SequenceIdGenerator('scenario');
    expect([ids.next(), ids.next()]).toEqual(['scenario-1', 'scenario-2']);
  });
});
