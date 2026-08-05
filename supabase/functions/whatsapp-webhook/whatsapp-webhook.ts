export type WhatsAppInboxEvent = {
  externalEventId: string;
  eventType: string;
  contact?: string;
  payload: Record<string, unknown>;
};

type WhatsAppChange = {
  field?: unknown;
  value?: unknown;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function cleanToken(value: unknown, fallback: string): string {
  if (typeof value !== 'string' || value.length === 0) return fallback;
  return value.replace(/[^a-zA-Z0-9_.:-]/g, '_').slice(0, 160);
}

function compactPayload(
  object: string,
  entryId: string,
  field: string,
  metadata: Record<string, unknown>,
  itemKind: 'message' | 'status' | 'error' | 'change',
  item: Record<string, unknown>
): Record<string, unknown> {
  return { object, entryId, field, metadata, [itemKind]: item };
}

export function extractWhatsAppEvents(
  payload: unknown,
  deliverySha256: string
): { wabaId: string; phoneNumberId: string; events: WhatsAppInboxEvent[] } | null {
  if (!isRecord(payload) || payload.object !== 'whatsapp_business_account') return null;

  const entries = Array.isArray(payload.entry) ? payload.entry : [];
  const events: WhatsAppInboxEvent[] = [];
  let resolvedWabaId = '';
  let resolvedPhoneNumberId = '';

  for (const [entryIndex, entryValue] of entries.entries()) {
    if (!isRecord(entryValue)) continue;
    const entryId = cleanToken(entryValue.id, `entry-${entryIndex}`);
    if (!resolvedWabaId && typeof entryValue.id === 'string') resolvedWabaId = entryValue.id;
    const changes = Array.isArray(entryValue.changes) ? entryValue.changes : [];

    for (const [changeIndex, rawChange] of changes.entries()) {
      if (!isRecord(rawChange)) continue;
      const change = rawChange as WhatsAppChange;
      const field = cleanToken(change.field, 'unknown');
      if (!isRecord(change.value)) continue;
      const value = change.value;
      const metadata = isRecord(value.metadata) ? value.metadata : {};
      const phoneNumberId =
        typeof metadata.phone_number_id === 'string' ? metadata.phone_number_id : '';
      if (!resolvedPhoneNumberId && phoneNumberId) resolvedPhoneNumberId = phoneNumberId;

      const messages = Array.isArray(value.messages) ? value.messages : [];
      for (const [messageIndex, rawMessage] of messages.entries()) {
        if (!isRecord(rawMessage)) continue;
        const messageId = cleanToken(
          rawMessage.id,
          `${deliverySha256}:message:${entryIndex}:${changeIndex}:${messageIndex}`
        );
        const messageType = cleanToken(rawMessage.type, 'unknown').toUpperCase();
        const contact = typeof rawMessage.from === 'string' ? rawMessage.from : undefined;
        events.push({
          externalEventId: `message:${messageId}`,
          eventType: `WHATSAPP_MESSAGE_${messageType}`,
          ...(contact ? { contact } : {}),
          payload: compactPayload(
            'whatsapp_business_account',
            entryId,
            field,
            metadata,
            'message',
            rawMessage
          ),
        });
      }

      const statuses = Array.isArray(value.statuses) ? value.statuses : [];
      for (const [statusIndex, rawStatus] of statuses.entries()) {
        if (!isRecord(rawStatus)) continue;
        const messageId = cleanToken(
          rawStatus.id,
          `${deliverySha256}:status:${entryIndex}:${changeIndex}:${statusIndex}`
        );
        const status = cleanToken(rawStatus.status, 'unknown').toUpperCase();
        const timestamp = cleanToken(rawStatus.timestamp, 'unknown');
        const contact =
          typeof rawStatus.recipient_id === 'string' ? rawStatus.recipient_id : undefined;
        events.push({
          externalEventId: `status:${messageId}:${status}:${timestamp}`,
          eventType: `WHATSAPP_STATUS_${status}`,
          ...(contact ? { contact } : {}),
          payload: compactPayload(
            'whatsapp_business_account',
            entryId,
            field,
            metadata,
            'status',
            rawStatus
          ),
        });
      }

      const errors = Array.isArray(value.errors) ? value.errors : [];
      for (const [errorIndex, rawError] of errors.entries()) {
        if (!isRecord(rawError)) continue;
        const code = cleanToken(String(rawError.code ?? 'unknown'), 'unknown');
        events.push({
          externalEventId: `error:${code}:${deliverySha256}:${entryIndex}:${changeIndex}:${errorIndex}`,
          eventType: `WHATSAPP_ERROR_${code.toUpperCase()}`,
          payload: compactPayload(
            'whatsapp_business_account',
            entryId,
            field,
            metadata,
            'error',
            rawError
          ),
        });
      }

      if (messages.length === 0 && statuses.length === 0 && errors.length === 0) {
        events.push({
          externalEventId: `change:${deliverySha256}:${entryIndex}:${changeIndex}`,
          eventType: `WHATSAPP_CHANGE_${field.toUpperCase()}`,
          payload: compactPayload('whatsapp_business_account', entryId, field, metadata, 'change', {
            deliverySha256,
          }),
        });
      }
    }
  }

  if (!resolvedWabaId || !resolvedPhoneNumberId || events.length === 0 || events.length > 100) {
    return null;
  }

  return { wabaId: resolvedWabaId, phoneNumberId: resolvedPhoneNumberId, events };
}

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((part) => part.toString(16).padStart(2, '0'))
    .join('');
}

export async function sha256Hex(value: string): Promise<string> {
  return toHex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

export function verifyToken(received: string | null, expected: string): boolean {
  return received !== null && expected.length >= 24 && constantTimeEqual(received, expected);
}

export async function verifyMetaSignature(
  rawBody: string,
  appSecret: string,
  signatureHeader: string | null
): Promise<boolean> {
  if (!signatureHeader || !/^sha256=[a-f0-9]{64}$/i.test(signatureHeader)) return false;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(appSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  return constantTimeEqual(`sha256=${toHex(signature)}`, signatureHeader.toLowerCase());
}
