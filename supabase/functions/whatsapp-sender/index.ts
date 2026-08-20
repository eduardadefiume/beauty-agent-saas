// whatsapp-sender — consome a fila de saida e entrega na Cloud API da Meta.
//
// Roda como worker: cada invocacao reserva um lote de mensagens PENDING, tenta
// entregar cada uma e registra o desfecho. Nao decide nada de negocio — a
// validacao da janela de 24h e a idempotencia ja aconteceram no enfileiramento,
// dentro do banco.
//
// Por que reservar antes de enviar: claim_outbox_batch marca SENDING numa
// transacao propria, com FOR UPDATE SKIP LOCKED. Duas invocacoes simultaneas
// pegam lotes disjuntos, entao a mesma mensagem nunca sai duas vezes.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

// As RPCs sao chamadas pelo nome simples, sem Content-Profile: o PostgREST
// deste projeto expoe apenas public e graphql_public. A logica vive em app e
// public guarda fachadas finas -- mesmo padrao de public.ingest_whatsapp_webhook.
const GRAPH_VERSION = 'v21.0';

type Reservada = {
  id: string;
  tenant_id: string;
  sender_id: string | null;
  recipient_address: string;
  kind: string;
  body_text: string | null;
  attempts: number;
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

async function rpc(url: string, key: string, fn: string, args: unknown): Promise<unknown> {
  const resposta = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  if (!resposta.ok) {
    throw new Error(`RPC ${fn} falhou: ${resposta.status} ${await resposta.text()}`);
  }
  return await resposta.json();
}

Deno.serve(async () => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const accessToken = Deno.env.get('WHATSAPP_ACCESS_TOKEN');

  if (!supabaseUrl || !serviceKey) {
    return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  }
  if (!accessToken) {
    // Sem token nao ha o que tentar. Devolve cedo em vez de reservar mensagens
    // e falhar todas, o que so gastaria tentativas do recuo exponencial.
    return json(500, { ok: false, reason: 'WHATSAPP_ACCESS_TOKEN_MISSING' });
  }

  let reservadas: Reservada[];
  try {
    reservadas = (await rpc(supabaseUrl, serviceKey, 'claim_outbox_batch', {
      p_limit: 20,
    })) as Reservada[];
  } catch (erro) {
    return json(500, { ok: false, reason: 'CLAIM_FAILED', detail: String(erro) });
  }

  if (!Array.isArray(reservadas) || reservadas.length === 0) {
    return json(200, { ok: true, reservadas: 0, enviadas: 0, falhadas: 0 });
  }

  let enviadas = 0;
  let falhadas = 0;

  for (const item of reservadas) {
    let sucesso = false;
    let providerMessageId: string | null = null;
    let erroTexto: string | null = null;

    try {
      if (!item.sender_id) {
        throw new Error('conexao sem external_sender_id — canal nao configurado');
      }
      if (item.kind !== 'TEXT') {
        throw new Error(`tipo ${item.kind} ainda nao suportado pelo worker`);
      }

      const resposta = await fetch(
        `https://graph.facebook.com/${GRAPH_VERSION}/${item.sender_id}/messages`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${accessToken}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            messaging_product: 'whatsapp',
            recipient_type: 'individual',
            to: item.recipient_address,
            type: 'text',
            text: { preview_url: false, body: item.body_text ?? '' },
          }),
        },
      );

      const corpo = await resposta.text();
      if (!resposta.ok) {
        throw new Error(`Graph ${resposta.status}: ${corpo.slice(0, 400)}`);
      }

      const dados = JSON.parse(corpo) as { messages?: Array<{ id?: string }> };
      providerMessageId = dados.messages?.[0]?.id ?? null;
      if (!providerMessageId) {
        throw new Error(`resposta sem id de mensagem: ${corpo.slice(0, 200)}`);
      }
      sucesso = true;
    } catch (erro) {
      erroTexto = String(erro);
    }

    try {
      await rpc(supabaseUrl, serviceKey, 'mark_outbox_result', {
        p_outbox_id: item.id,
        p_success: sucesso,
        p_provider_message_id: providerMessageId,
        p_error: erroTexto,
      });
    } catch (erro) {
      // Se o registro do desfecho falhar, a mensagem fica em SENDING. E melhor
      // ficar presa e visivel do que ser reenviada as cegas.
      console.error(JSON.stringify({ event: 'mark_result_failed', outboxId: item.id, erro: String(erro) }));
    }

    if (sucesso) enviadas++;
    else falhadas++;
  }

  console.log(JSON.stringify({
    event: 'outbox_drained',
    reservadas: reservadas.length,
    enviadas,
    falhadas,
  }));

  return json(200, { ok: true, reservadas: reservadas.length, enviadas, falhadas });
});
