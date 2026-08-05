import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

import {
  extractWhatsAppEvents,
  sha256Hex,
  verifyMetaSignature,
  verifyToken,
} from './whatsapp-webhook.ts';

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
  if (Number.isFinite(declaredLength) && declaredLength > 1_000_000) {
    return json({ code: 'PAYLOAD_TOO_LARGE' }, 413);
  }

  const rawBody = await req.text();
  if (rawBody.length === 0 || rawBody.length > 1_000_000) {
    return json({ code: 'INVALID_PAYLOAD_SIZE' }, rawBody.length > 1_000_000 ? 413 : 400);
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

  const delivery = extractWhatsAppEvents(payload, payloadSha256);
  if (!delivery) return json({ code: 'INVALID_WHATSAPP_PAYLOAD', correlationId }, 400);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const secretKey = readSecretKey();
  if (!supabaseUrl || !secretKey) {
    return json({ code: 'DATABASE_INTEGRATION_NOT_CONFIGURED', correlationId }, 503);
  }

  const databaseResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/ingest_whatsapp_webhook`, {
    method: 'POST',
    headers: {
      apikey: secretKey,
      Authorization: `Bearer ${secretKey}`,
      'Content-Type': 'application/json',
      'Content-Profile': 'api',
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
