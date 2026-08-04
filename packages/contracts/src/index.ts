import { z } from 'zod';

const brandedUuid = <T extends string>() => z.uuid().brand<T>();

export const TenantIdSchema = brandedUuid<'TenantId'>();
export const UnitIdSchema = brandedUuid<'UnitId'>();
export const ConfigurationVersionIdSchema = brandedUuid<'ConfigurationVersionId'>();
export const CorrelationIdSchema = z.string().min(8).max(128).brand<'CorrelationId'>();
export const IsoDateTimeSchema = z.iso.datetime({ offset: true });
export const IanaTimezoneSchema = z.string().refine(
  (value) => {
    try {
      Intl.DateTimeFormat('en-US', { timeZone: value });
      return true;
    } catch {
      return false;
    }
  },
  { message: 'INVALID_IANA_TIMEZONE' }
);

export const ApiErrorSchema = z.object({
  code: z.string().min(1),
  message: z.string().min(1),
  correlationId: CorrelationIdSchema,
  details: z.record(z.string(), z.unknown()).optional(),
});

export const PageRequestSchema = z.object({
  cursor: z.string().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(25),
});

export type TenantId = z.infer<typeof TenantIdSchema>;
export type UnitId = z.infer<typeof UnitIdSchema>;
export type ConfigurationVersionId = z.infer<typeof ConfigurationVersionIdSchema>;
export type CorrelationId = z.infer<typeof CorrelationIdSchema>;
