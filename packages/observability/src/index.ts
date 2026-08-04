const forbiddenKeys = /token|authorization|cookie|secret|password|media|payload/i;

export function minimizeLogMetadata(
  metadata: Readonly<Record<string, unknown>>
): Readonly<Record<string, unknown>> {
  return Object.fromEntries(Object.entries(metadata).filter(([key]) => !forbiddenKeys.test(key)));
}
