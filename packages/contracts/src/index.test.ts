import { describe, expect, it } from 'vitest';

import { IanaTimezoneSchema, IsoDateTimeSchema, PageRequestSchema } from './index.js';

describe('base contracts', () => {
  it('accepts an IANA timezone and rejects an invented one', () => {
    expect(IanaTimezoneSchema.parse('America/Sao_Paulo')).toBe('America/Sao_Paulo');
    expect(() => IanaTimezoneSchema.parse('Brazil/Ribeirao_Preto')).toThrow();
  });

  it('requires an explicit offset in API timestamps', () => {
    expect(IsoDateTimeSchema.parse('2026-08-03T18:00:00Z')).toBe('2026-08-03T18:00:00Z');
    expect(() => IsoDateTimeSchema.parse('2026-08-03T18:00:00')).toThrow();
  });

  it('caps page size', () => {
    expect(PageRequestSchema.parse({}).limit).toBe(25);
    expect(() => PageRequestSchema.parse({ limit: 101 })).toThrow();
  });
});
