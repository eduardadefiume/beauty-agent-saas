import type { CorrelationId } from '@beauty/contracts';

export interface Clock {
  now(): Date;
}

export interface IdGenerator {
  next(): string;
}

export interface LogContext {
  correlationId: CorrelationId;
  tenantId?: string;
  unitId?: string;
}

export interface DomainLogger {
  info(context: LogContext, event: string, metadata?: Readonly<Record<string, unknown>>): void;
  warn(context: LogContext, event: string, metadata?: Readonly<Record<string, unknown>>): void;
  error(context: LogContext, event: string, metadata?: Readonly<Record<string, unknown>>): void;
}

export class SystemClock implements Clock {
  now(): Date {
    return new Date();
  }
}

export class FixedClock implements Clock {
  constructor(private readonly instant: Date) {}

  now(): Date {
    return new Date(this.instant.getTime());
  }
}

export class SequenceIdGenerator implements IdGenerator {
  private cursor = 0;

  constructor(private readonly prefix = 'test') {}

  next(): string {
    this.cursor += 1;
    return `${this.prefix}-${this.cursor}`;
  }
}
