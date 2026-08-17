export type NormalizedWhatsAppEvent = {
  eventKey: string;
  eventType: string;
  kind: 'INBOUND_MESSAGE' | 'MESSAGE_STATUS' | 'UNSUPPORTED_CHANGE';
  messageId?: string;
  contactPhone?: string;
  contactName?: string;
  body?: string;
  status?: 'SENT' | 'DELIVERED' | 'READ' | 'FAILED';
};

export type NormalizedWhatsAppWebhook = {
  wabaId: string;
  phoneNumberId: string;
  events: NormalizedWhatsAppEvent[];
};

type RecordValue = Record<string, unknown>;

const MAX_EVENTS_PER_DELIVERY = 100;
const MAX_BODY_LENGTH = 4096;

function isRecord(value: unknown): value is RecordValue {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function cleanIdentifier(value: unknown, maximumLength = 240): string | null {
  if (typeof value !== 'string') return null;
  const cleaned = value.replace(/[^a-zA-Z0-9_.:-]/g, '_').slice(0, maximumLength);
  return cleaned.length > 0 ? cleaned : null;
}

function normalizePhone(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const digits = value.replace(/\D/g, '');
  return /^[0-9]{8,20}$/.test(digits) ? digits : null;
}

function cleanBody(value: unknown, messageType: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value.slice(0, MAX_BODY_LENGTH);
  }
  return `[UNSUPPORTED_MESSAGE:${messageType}]`;
}

function profileName(contacts: unknown, contactPhone: string | null): string | undefined {
  if (!Array.isArray(contacts) || !contactPhone) return undefined;
  const contact = contacts.find(
    (candidate) =>
      isRecord(candidate) && normalizePhone(candidate.wa_id) === contactPhone && isRecord(candidate.profile)
  );
  if (!isRecord(contact) || !isRecord(contact.profile) || typeof contact.profile.name !== 'string') {
    return undefined;
  }
  const name = contact.profile.name.trim().slice(0, 200);
  return name.length > 0 ? name : undefined;
}

function textMessageBody(message: RecordValue, messageType: string): string {
  const text = isRecord(message.text) ? message.text.body : undefined;
  return cleanBody(text, messageType);
}

function isDeliveryStatus(value: string): value is NonNullable<NormalizedWhatsAppEvent['status']> {
  return value === 'SENT' || value === 'DELIVERED' || value === 'READ' || value === 'FAILED';
}

export function normalizeMetaWebhook(payload: unknown): NormalizedWhatsAppWebhook | null {
  if (!isRecord(payload) || payload.object !== 'whatsapp_business_account') return null;

  let wabaId: string | null = null;
  let phoneNumberId: string | null = null;
  const events: NormalizedWhatsAppEvent[] = [];
  const entries = Array.isArray(payload.entry) ? payload.entry : [];

  for (const entry of entries) {
    if (!isRecord(entry)) continue;
    const entryWabaId = cleanIdentifier(entry.id);
    if (!wabaId && entryWabaId) wabaId = entryWabaId;

    const changes = Array.isArray(entry.changes) ? entry.changes : [];
    for (const change of changes) {
      if (!isRecord(change) || !isRecord(change.value)) continue;
      const value = change.value;
      const metadata = isRecord(value.metadata) ? value.metadata : {};
      const changePhoneNumberId = cleanIdentifier(metadata.phone_number_id);
      if (!phoneNumberId && changePhoneNumberId) phoneNumberId = changePhoneNumberId;

      const messages = Array.isArray(value.messages) ? value.messages : [];
      for (const message of messages) {
        if (!isRecord(message)) continue;
        const messageId = cleanIdentifier(message.id, 200);
        const contactPhone = normalizePhone(message.from);
        const messageType = (cleanIdentifier(message.type) ?? 'unknown').toUpperCase();
        if (!messageId || !contactPhone) continue;
        const contactName = profileName(value.contacts, contactPhone);

        events.push({
          eventKey: `message:${messageId}`,
          eventType: `WHATSAPP_MESSAGE_${messageType}`,
          kind: 'INBOUND_MESSAGE',
          messageId,
          contactPhone,
          ...(contactName ? { contactName } : {}),
          body: textMessageBody(message, messageType),
        });
      }

      const statuses = Array.isArray(value.statuses) ? value.statuses : [];
      for (const deliveryStatus of statuses) {
        if (!isRecord(deliveryStatus)) continue;
        const messageId = cleanIdentifier(deliveryStatus.id, 190);
        const status = (cleanIdentifier(deliveryStatus.status) ?? '').toUpperCase();
        const timestamp = cleanIdentifier(deliveryStatus.timestamp) ?? 'unknown';
        if (!messageId || !isDeliveryStatus(status)) continue;

        events.push({
          eventKey: `status:${messageId}:${status}:${timestamp}`,
          eventType: `WHATSAPP_STATUS_${status}`,
          kind: 'MESSAGE_STATUS',
          messageId,
          status,
        });
      }

      if (messages.length === 0 && statuses.length === 0 && changePhoneNumberId) {
        const field = cleanIdentifier(change.field) ?? 'unknown';
        events.push({
          eventKey: `change:${entryWabaId ?? 'unknown'}:${changePhoneNumberId}:${field}`,
          eventType: `WHATSAPP_CHANGE_${field.toUpperCase()}`,
          kind: 'UNSUPPORTED_CHANGE',
        });
      }

      if (events.length > MAX_EVENTS_PER_DELIVERY) return null;
    }
  }

  if (!wabaId || !phoneNumberId || events.length === 0) return null;
  return { wabaId, phoneNumberId, events };
}
