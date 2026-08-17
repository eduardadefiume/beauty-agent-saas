import { describe, expect, it } from 'vitest';
import { normalizeMetaWebhook } from './normalizer';

type FixtureMessage = Record<string, unknown>;

function createPayload(
  message: FixtureMessage,
  statuses: FixtureMessage[] = [
    {
      id: 'wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY',
      status: 'delivered',
      timestamp: '1776000000',
    },
  ]
) {
  return {
  object: 'whatsapp_business_account',
  entry: [
    {
      id: '123456789012345',
      changes: [
        {
          field: 'messages',
          value: {
            metadata: { phone_number_id: '987654321098765' },
            contacts: [{ wa_id: '5516994215487', profile: { name: 'Duda' } }],
            messages: [message],
            statuses,
          },
        },
      ],
    },
  ],
  };
}

function textMessage(from = '5516994215487'): FixtureMessage {
  return {
    id: 'wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY',
    from,
    type: 'text',
    text: { body: 'SMOKE G3 nonce-123' },
  };
}

describe('normalizeMetaWebhook', () => {
  it('normaliza mensagens e status sem reter payload bruto', () => {
    const result = normalizeMetaWebhook(createPayload(textMessage()));

    expect(result).toEqual({
      wabaId: '123456789012345',
      phoneNumberId: '987654321098765',
      events: [
        {
          eventKey: 'message:wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY',
          eventType: 'WHATSAPP_MESSAGE_TEXT',
          kind: 'INBOUND_MESSAGE',
          messageId: 'wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY',
          contactPhone: '5516994215487',
          contactName: 'Duda',
          body: 'SMOKE G3 nonce-123',
        },
        {
          eventKey: 'status:wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY:DELIVERED:1776000000',
          eventType: 'WHATSAPP_STATUS_DELIVERED',
          kind: 'MESSAGE_STATUS',
          messageId: 'wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY',
          status: 'DELIVERED',
        },
      ],
    });
  });

  it('rejeita payload que não é evento WhatsApp', () => {
    expect(normalizeMetaWebhook({ object: 'instagram' })).toBeNull();
  });

  it('descarta mensagem sem telefone válido sem bloquear um status válido no mesmo webhook', () => {
    expect(normalizeMetaWebhook(createPayload(textMessage('not-a-phone')))?.events).toEqual([
      {
        eventKey: 'status:wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY:DELIVERED:1776000000',
        eventType: 'WHATSAPP_STATUS_DELIVERED',
        kind: 'MESSAGE_STATUS',
        messageId: 'wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIY',
        status: 'DELIVERED',
      },
    ]);
  });

  it('minimiza mensagem não textual sem descartar seu identificador de idempotência', () => {
    const mediaPayload = createPayload(
      { id: 'wamid.media-event', from: '5516994215487', type: 'image' },
      []
    );

    expect(normalizeMetaWebhook(mediaPayload)?.events[0]).toMatchObject({
      kind: 'INBOUND_MESSAGE',
      messageId: 'wamid.media-event',
      body: '[UNSUPPORTED_MESSAGE:IMAGE]',
    });
  });
});
