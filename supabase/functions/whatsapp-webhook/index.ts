import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

import {
  extractCoexistenceChanges,
  extractWhatsAppEvents,
  sha256Hex,
  verifyMetaSignature,
  verifyToken,
} from './whatsapp-webhook.ts';

// Uma entrega comum da Cloud API cabe folgada em 1 MB. Um pedaco de `history`
// do Coexistence carrega meses de conversa de varias clientes de uma vez, e
// nao cabe. O teto maior vale so depois de a assinatura da Meta conferir --
// nada nao assinado chega a ser lido como JSON.
const TETO_PADRAO = 1_000_000;
const TETO_HISTORICO = 12_000_000;

const jsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function readSecretKey(): string | null {
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>;
    if (keys.default) return keys.default;
  } catch {
    return null;
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? null;
}

async function handleVerification(req: Request, verifyTokenSecret: string): Promise<Response> {
  const url = new URL(req.url);
  const mode = url.searchParams.get('hub.mode');
  const challenge = url.searchParams.get('hub.challenge');
  const receivedToken = url.searchParams.get('hub.verify_token');

  if (
    mode !== 'subscribe' ||
    !challenge ||
    challenge.length > 512 ||
    !verifyToken(receivedToken, verifyTokenSecret)
  ) {
    return new Response('Forbidden', {
      status: 403,
      headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
    });
  }

  return new Response(challenge, {
    status: 200,
    headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  const verifyTokenSecret = Deno.env.get('WHATSAPP_VERIFY_TOKEN');
  const appSecret = Deno.env.get('META_APP_SECRET');

  if (!verifyTokenSecret || !appSecret) {
    return json({ code: 'WHATSAPP_WEBHOOK_NOT_CONFIGURED' }, 503);
  }

  if (req.method === 'GET') return handleVerification(req, verifyTokenSecret);
  if (req.method !== 'POST') return json({ code: 'METHOD_NOT_ALLOWED' }, 405);

  const declaredLength = Number(req.headers.get('content-length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > TETO_HISTORICO) {
    return json({ code: 'PAYLOAD_TOO_LARGE' }, 413);
  }

  const rawBody = await req.text();
  if (rawBody.length === 0 || rawBody.length > TETO_HISTORICO) {
    return json({ code: 'INVALID_PAYLOAD_SIZE' }, rawBody.length > TETO_HISTORICO ? 413 : 400);
  }

  if (!(await verifyMetaSignature(rawBody, appSecret, req.headers.get('x-hub-signature-256')))) {
    return json({ code: 'INVALID_META_SIGNATURE' }, 401);
  }

  const payloadSha256 = await sha256Hex(rawBody);
  const correlationId = `wa_${payloadSha256.slice(0, 32)}`;
  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return json({ code: 'INVALID_JSON', correlationId }, 400);
  }

  const coexistencia = extractCoexistenceChanges(payload);

  // Fora do Coexistence o teto continua sendo o de sempre.
  if (coexistencia.length === 0 && rawBody.length > TETO_PADRAO) {
    return json({ code: 'PAYLOAD_TOO_LARGE', correlationId }, 413);
  }

  const delivery = extractWhatsAppEvents(payload, payloadSha256);
  if (!delivery && coexistencia.length === 0) {
    return json({ code: 'INVALID_WHATSAPP_PAYLOAD', correlationId }, 400);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const secretKey = readSecretKey();
  if (!supabaseUrl || !secretKey) {
    return json({ code: 'DATABASE_INTEGRATION_NOT_CONFIGURED', correlationId }, 503);
  }

  // O historico entra primeiro e sem recorte. Se o banco recusar, a resposta
  // NAO e 200: a Meta reenvia, e reenvio e a unica chance de recuperar um
  // pedaco de historico que so e oferecido uma vez.
  for (const mudanca of coexistencia) {
    const resposta = await fetch(`${supabaseUrl}/rest/v1/rpc/ingest_whatsapp_coexistence`, {
      method: 'POST',
      headers: {
        apikey: secretKey,
        Authorization: `Bearer ${secretKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        p_waba_id: mudanca.wabaId,
        p_phone_number_id: mudanca.phoneNumberId,
        p_field: mudanca.field,
        p_payload_sha256: payloadSha256,
        p_value: mudanca.value,
      }),
    });

    if (!resposta.ok) {
      console.error(
        JSON.stringify({
          event: 'whatsapp_coexistence_persistence_failed',
          correlationId,
          field: mudanca.field,
          status: resposta.status,
        })
      );
      return json({ code: 'COEXISTENCE_PERSISTENCE_FAILED', correlationId }, 503);
    }

    const lido = (await resposta.json()) as Record<string, unknown>;
    console.log(
      JSON.stringify({
        event: 'whatsapp_coexistence_persisted',
        correlationId,
        field: mudanca.field,
        duplicada: lido.duplicada ?? false,
        parseFalhou: lido.parseFalhou ?? false,
      })
    );
  }

  if (!delivery) return json({ received: true, correlationId }, 200);

  // SEM `Content-Profile: api`. O schema `api` nao esta na lista que o
  // PostgREST expoe (so `public` e `graphql_public`), e com o cabecalho toda
  // entrega recebia 406 "Invalid schema: api" -> este webhook devolvia 503 ->
  // a Meta reenviava -> 406 de novo. Nenhuma mensagem chegou ao banco entre a
  // v14 e a v15. O invólucro public.ingest_whatsapp_webhook chama o mesmo
  // api.ingest_whatsapp_webhook; e o caminho que o Coexistence acima ja usa.
  const databaseResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/ingest_whatsapp_webhook`, {
    method: 'POST',
    headers: {
      apikey: secretKey,
      Authorization: `Bearer ${secretKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_waba_id: delivery.wabaId,
      p_phone_number_id: delivery.phoneNumberId,
      p_payload_sha256: payloadSha256,
      p_correlation_id: correlationId,
      p_events: delivery.events,
    }),
  });

  if (!databaseResponse.ok) {
    console.error(
      JSON.stringify({
        event: 'whatsapp_webhook_persistence_failed',
        correlationId,
        status: databaseResponse.status,
      })
    );
    return json({ code: 'WEBHOOK_PERSISTENCE_FAILED', correlationId }, 503);
  }

  const result = (await databaseResponse.json()) as Record<string, unknown>;

  // ACORDA QUEM TRABALHA, AGORA.
  //
  // 23/09/2026. Ate hoje a mensagem chegava aqui na hora e depois esperava
  // DOIS relogios de um minuto: um para `project_inbox_events` virar conversa,
  // outro para o worker do agente acordar. Medido numa conversa real: 49
  // segundos so de espera antes de o Eddy ver o que a dona tinha escrito.
  //
  // O evento que importa ja aconteceu -- e esta mensagem. Entao ela mesma
  // acorda. O cron continua ligado como rede de seguranca, nao como caminho.
  //
  // Nao esperamos o resultado influenciar a resposta a Meta: a Meta quer um
  // 200 rapido e reenvia se demorar. Se acordar falhar, o cron pega no proximo
  // minuto -- o pior caso e voltar a ser o que era.
  // SO MENSAGEM DE VERDADE ACORDA ALGUEM. A Meta manda um webhook para cada
  // recibo de "enviado", "entregue" e "lido" -- na conversa de hoje foram
  // quatro recibos para duas mensagens. Acordar o agente em cada um seria
  // dobrar as chamadas para ele nao achar nada.
  const temMensagemNova = (delivery.events ?? []).some((e: { eventType?: string }) =>
    String(e.eventType ?? '').startsWith('WHATSAPP_MESSAGE_')
  );

  if (temMensagemNova && Number(result.accepted ?? 0) > 0) {
    try {
      const acordou = await fetch(`${supabaseUrl}/rest/v1/rpc/acordar_atendimento_agora`, {
        method: 'POST',
        headers: {
          apikey: secretKey,
          Authorization: `Bearer ${secretKey}`,
          'Content-Type': 'application/json',
        },
        body: '{}',
      });
      if (!acordou.ok) {
        console.error(
          JSON.stringify({
            event: 'whatsapp_webhook_wake_failed',
            correlationId,
            status: acordou.status,
          })
        );
      }
    } catch (erro) {
      console.error(
        JSON.stringify({
          event: 'whatsapp_webhook_wake_threw',
          correlationId,
          erro: String(erro).slice(0, 200),
        })
      );
    }
  }

  console.log(
    JSON.stringify({
      event: 'whatsapp_webhook_persisted',
      correlationId,
      knownConnection: result.knownConnection,
      accepted: result.accepted,
      rejected: result.rejected,
      duplicates: result.duplicates,
    })
  );

  return json({ received: true, correlationId }, 200);
});
