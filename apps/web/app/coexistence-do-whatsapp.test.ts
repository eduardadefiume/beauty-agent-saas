import { describe, expect, it } from 'vitest';
import {
  CAMPOS_COEXISTENCE,
  extractCoexistenceChanges,
  extractWhatsAppEvents,
} from '../../../supabase/functions/whatsapp-webhook/whatsapp-webhook';

// O que este teste tranca: o webhook não pode jogar fora o conteúdo de um
// campo que ele não conhecia.
//
// Antes daqui, uma entrega com `field: "history"` caía no ramo de "houve uma
// mudança": o webhook respondia 200, gravava a metadata e descartava o
// `value`. A Meta oferece cada pedaço do histórico uma vez. Um 200 em cima de
// um pedaço descartado é o histórico do salão perdido em silêncio, sem erro,
// sem log, sem jeito de perceber depois.
//
// Por isso o teste central aqui não é "o parser lê certo" — é "o `value`
// inteiro chega do outro lado".

function entrega(field: string, value: Record<string, unknown>) {
  return {
    object: 'whatsapp_business_account',
    entry: [{ id: '111222333', changes: [{ field, value }] }],
  };
}

const HISTORICO = entrega('history', {
  messaging_product: 'whatsapp',
  metadata: { display_phone_number: '5516981064232', phone_number_id: '999888777' },
  history: [
    {
      metadata: { phase: 0, chunk_order: 1, progress: 12 },
      threads: [
        {
          id: '5516999990001',
          messages: [
            {
              id: 'wamid.A',
              from: '5516999990001',
              timestamp: '1756900000',
              type: 'text',
              text: { body: 'oi, quanto ta a progressiva?' },
            },
            {
              id: 'wamid.B',
              from: '5516981064232',
              timestamp: '1756900060',
              type: 'text',
              text: { body: 'oi linda! depende do comprimento' },
            },
          ],
        },
      ],
    },
  ],
});

describe('o histórico do Coexistence chega inteiro', () => {
  it('entrega o value sem recorte, com as mensagens dentro', () => {
    const mudancas = extractCoexistenceChanges(HISTORICO);
    expect(mudancas).toHaveLength(1);
    const mudanca = mudancas[0]!;

    expect(mudanca.field).toBe('history');
    expect(mudanca.wabaId).toBe('111222333');
    expect(mudanca.phoneNumberId).toBe('999888777');

    // O ponto do teste: o conteúdo, não a metadata.
    const historico = mudanca.value.history as Array<Record<string, unknown>>;
    const threads = historico[0]!.threads as Array<Record<string, unknown>>;
    const mensagens = threads[0]!.messages as Array<Record<string, unknown>>;
    expect(mensagens).toHaveLength(2);
    expect((mensagens[0]!.text as Record<string, string>).body).toContain('progressiva');
  });

  it('o caminho antigo não toca mais nesses campos', () => {
    // Se voltasse a tocar, geraria um evento WHATSAPP_CHANGE_HISTORY vazio e o
    // conteúdo seria descartado de novo -- exatamente o defeito que isto trava.
    expect(extractWhatsAppEvents(HISTORICO, 'a'.repeat(64))).toBeNull();
  });

  it('lê os três campos do Coexistence e ignora o resto', () => {
    expect(CAMPOS_COEXISTENCE).toEqual(['history', 'smb_app_state_sync', 'smb_message_echoes']);

    const agenda = entrega('smb_app_state_sync', {
      metadata: { display_phone_number: '5516981064232', phone_number_id: '999888777' },
      state_sync: [
        {
          type: 'contact',
          contact: { full_name: 'Andreia Souza', phone_number: '+55 16 99999-0001' },
          action: 'add',
        },
      ],
    });
    expect(extractCoexistenceChanges(agenda)).toHaveLength(1);

    expect(
      extractCoexistenceChanges(entrega('messages', { metadata: {}, messages: [] }))
    ).toHaveLength(0);
    expect(extractCoexistenceChanges(entrega('account_update', { metadata: {} }))).toHaveLength(0);
  });

  it('uma entrega mista não perde nenhum dos dois lados', () => {
    const mista = {
      object: 'whatsapp_business_account',
      entry: [
        {
          id: '111222333',
          changes: [
            {
              field: 'messages',
              value: {
                metadata: { phone_number_id: '999888777' },
                messages: [
                  { id: 'wamid.C', from: '5516999990002', type: 'text', text: { body: 'oi' } },
                ],
              },
            },
            {
              field: 'history',
              value: (HISTORICO.entry[0]!.changes[0] as { value: unknown }).value,
            },
          ],
        },
      ],
    };

    expect(extractCoexistenceChanges(mista)).toHaveLength(1);
    const eventos = extractWhatsAppEvents(mista, 'b'.repeat(64));
    expect(eventos?.events).toHaveLength(1);
    expect(eventos?.events[0]!.eventType).toBe('WHATSAPP_MESSAGE_TEXT');
  });

  it('payload torto não derruba nem inventa mudança', () => {
    expect(extractCoexistenceChanges(null)).toEqual([]);
    expect(extractCoexistenceChanges({ object: 'page', entry: [] })).toEqual([]);
    expect(extractCoexistenceChanges(entrega('history', undefined as never))).toEqual([]);
    expect(
      extractCoexistenceChanges({
        object: 'whatsapp_business_account',
        entry: [{ id: '111', changes: 'nao e lista' }],
      })
    ).toEqual([]);
  });
});
