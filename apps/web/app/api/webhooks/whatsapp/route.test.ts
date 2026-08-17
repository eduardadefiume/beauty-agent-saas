import { beforeEach, describe, expect, it, vi } from 'vitest';

const { ingestMock } = vi.hoisted(() => ({ ingestMock: vi.fn() }));

vi.mock('../../../../lib/whatsapp-webhook/ingestion', () => ({
  ingestVerifiedWhatsAppWebhook: ingestMock,
}));

import { GET, POST } from './route';

const encoder = new TextEncoder();

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((part) => part.toString(16).padStart(2, '0'))
    .join('');
}

async function metaSignature(body: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(process.env.META_APP_SECRET!),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const bytes = body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) as ArrayBuffer;
  return `sha256=${toHex(await crypto.subtle.sign('HMAC', key, bytes))}`;
}

function inboundPayload(): string {
  return JSON.stringify({
    object: 'whatsapp_business_account',
    entry: [
      {
        id: 'test-waba-id',
        changes: [
          {
            field: 'messages',
            value: {
              metadata: { phone_number_id: 'test-phone-id' },
              contacts: [{ wa_id: '5516994215487', profile: { name: 'Piloto' } }],
              messages: [
                {
                  id: 'wamid.route-test-001',
                  from: '5516994215487',
                  timestamp: '1786982400',
                  type: 'text',
                  text: { body: 'SMOKE ROUTE' },
                },
              ],
            },
          },
        ],
      },
    ],
  });
}

describe('WhatsApp webhook route', () => {
  beforeEach(() => {
    process.env.META_APP_SECRET = 'route-test-app-secret';
    process.env.META_WEBHOOK_VERIFY_TOKEN = 'route-test-token-with-minimum-length';
    ingestMock.mockReset();
  });

  it('confirma o desafio GET somente com token válido', async () => {
    const response = await GET(
      new Request(
        'https://wa-dev.example/api/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=route-test-token-with-minimum-length&hub.challenge=challenge-123'
      )
    );

    expect(response.status).toBe(200);
    await expect(response.text()).resolves.toBe('challenge-123');
  });

  it('rejeita GET com token incorreto', async () => {
    const response = await GET(
      new Request(
        'https://wa-dev.example/api/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=wrong-token-with-minimum-length&hub.challenge=challenge-123'
      )
    );

    expect(response.status).toBe(403);
  });

  it('rejeita POST sem assinatura antes de chamar a ingestão', async () => {
    const response = await POST(
      new Request('https://wa-dev.example/api/webhooks/whatsapp', {
        method: 'POST',
        body: inboundPayload(),
      })
    );

    expect(response.status).toBe(401);
    expect(ingestMock).not.toHaveBeenCalled();
  });

  it('aceita payload assinado e projeta uma única entrega normalizada', async () => {
    const body = encoder.encode(inboundPayload());
    ingestMock.mockResolvedValue({ knownChannel: true, accepted: 1, duplicates: 0, ignored: 0 });

    const response = await POST(
      new Request('https://wa-dev.example/api/webhooks/whatsapp', {
        method: 'POST',
        headers: { 'x-hub-signature-256': await metaSignature(body) },
        body,
      })
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      status: 'accepted',
      accepted: 1,
      duplicates: 0,
    });
    expect(ingestMock).toHaveBeenCalledTimes(1);
  });

  it('absorve canal desconhecido sem expor erro à Meta', async () => {
    const body = encoder.encode(inboundPayload());
    ingestMock.mockResolvedValue({ knownChannel: false, accepted: 0, duplicates: 0, ignored: 0 });

    const response = await POST(
      new Request('https://wa-dev.example/api/webhooks/whatsapp', {
        method: 'POST',
        headers: { 'x-hub-signature-256': await metaSignature(body) },
        body,
      })
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ status: 'ignored' });
  });
});
