import { describe, expect, it } from 'vitest';

import {
  extractWhatsAppEvents,
  sha256Hex,
  verifyMetaSignature,
  verifyToken,
} from './whatsapp-webhook.ts';

describe('WhatsApp webhook security', () => {
  it('validates the standard HMAC SHA-256 vector', async () => {
    await expect(
      verifyMetaSignature(
        'Hello, World!',
        "It's a Secret to Everybody",
        'sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17'
      )
    ).resolves.toBe(true);
  });

  it('rejects a changed payload and malformed signature', async () => {
    await expect(
      verifyMetaSignature(
        'Hello, World?',
        "It's a Secret to Everybody",
        'sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17'
      )
    ).resolves.toBe(false);
    await expect(verifyMetaSignature('{}', 'secret', 'bad')).resolves.toBe(false);
  });

  it('requires a long exact verification token', () => {
    expect(verifyToken('012345678901234567890123', '012345678901234567890123')).toBe(true);
    expect(verifyToken('different', '012345678901234567890123')).toBe(false);
    expect(verifyToken('short', 'short')).toBe(false);
  });
});

describe('WhatsApp webhook normalization', () => {
  it('extracts one message and one delivery status with stable external IDs', async () => {
    const payload = {
      object: 'whatsapp_business_account',
      entry: [
        {
          id: 'waba-1',
          changes: [
            {
              field: 'messages',
              value: {
                metadata: { phone_number_id: 'phone-1' },
                messages: [{ id: 'wamid.message-1', from: '5511999999999', type: 'text' }],
                statuses: [
                  {
                    id: 'wamid.outbound-1',
                    recipient_id: '5511999999999',
                    status: 'delivered',
                    timestamp: '1785940000',
                  },
                ],
              },
            },
          ],
        },
      ],
    };
    const hash = await sha256Hex(JSON.stringify(payload));
    const result = extractWhatsAppEvents(payload, hash);

    expect(result).not.toBeNull();
    expect(result?.wabaId).toBe('waba-1');
    expect(result?.phoneNumberId).toBe('phone-1');
    expect(result?.events.map((event) => event.externalEventId)).toEqual([
      'message:wamid.message-1',
      'status:wamid.outbound-1:DELIVERED:1785940000',
    ]);
  });

  it('rejects payloads from another webhook object', () => {
    expect(extractWhatsAppEvents({ object: 'page', entry: [] }, 'a'.repeat(64))).toBeNull();
  });
});
