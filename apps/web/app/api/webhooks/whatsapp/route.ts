import { NextResponse } from 'next/server';
import { ingestVerifiedWhatsAppWebhook } from '../../../../lib/whatsapp-webhook/ingestion';
import { normalizeMetaWebhook } from '../../../../lib/whatsapp-webhook/normalizer';
import {
  sha256Hex,
  verifyMetaSignature,
  verifyWebhookToken,
} from '../../../../lib/whatsapp-webhook/signature';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

const MAX_WEBHOOK_BYTES = 1_000_000;

function readWebhookConfiguration(): { appSecret: string; verifyToken: string } | null {
  const appSecret = process.env.META_APP_SECRET;
  const verifyToken = process.env.META_WEBHOOK_VERIFY_TOKEN;

  if (!appSecret || !verifyToken || verifyToken.length < 24) return null;
  return { appSecret, verifyToken };
}

function redactedFailure(event: string, correlationId: string): void {
  console.error(JSON.stringify({ event, correlationId }));
}

export async function GET(request: Request): Promise<Response> {
  const configuration = readWebhookConfiguration();
  if (!configuration) return new NextResponse(null, { status: 503 });

  const url = new URL(request.url);
  const mode = url.searchParams.get('hub.mode');
  const receivedToken = url.searchParams.get('hub.verify_token');
  const challenge = url.searchParams.get('hub.challenge');

  if (
    mode !== 'subscribe' ||
    !challenge ||
    !verifyWebhookToken(receivedToken, configuration.verifyToken)
  ) {
    return new NextResponse(null, { status: 403 });
  }

  return new NextResponse(challenge, {
    status: 200,
    headers: { 'content-type': 'text/plain; charset=utf-8' },
  });
}

export async function POST(request: Request): Promise<Response> {
  const correlationId = crypto.randomUUID();
  const configuration = readWebhookConfiguration();
  if (!configuration) {
    redactedFailure('WHATSAPP_WEBHOOK_CONFIGURATION_MISSING', correlationId);
    return new NextResponse(null, { status: 503 });
  }

  const declaredLength = Number(request.headers.get('content-length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > MAX_WEBHOOK_BYTES) {
    return new NextResponse(null, { status: 413 });
  }

  const rawBody = new Uint8Array(await request.arrayBuffer());
  if (rawBody.byteLength === 0 || rawBody.byteLength > MAX_WEBHOOK_BYTES) {
    return new NextResponse(null, { status: 413 });
  }

  const isValidSignature = await verifyMetaSignature(
    rawBody,
    configuration.appSecret,
    request.headers.get('x-hub-signature-256')
  );
  if (!isValidSignature) {
    redactedFailure('WHATSAPP_WEBHOOK_SIGNATURE_REJECTED', correlationId);
    return new NextResponse(null, { status: 401 });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(rawBody));
  } catch {
    redactedFailure('WHATSAPP_WEBHOOK_JSON_REJECTED', correlationId);
    return new NextResponse(null, { status: 400 });
  }

  const normalized = normalizeMetaWebhook(payload);
  if (!normalized) {
    // The delivery was authentic but irrelevant to the inbox projection. A 200
    // prevents Meta retries for subscriptions that this wedge deliberately ignores.
    return NextResponse.json({ status: 'ignored', correlationId }, { status: 200 });
  }

  try {
    const result = await ingestVerifiedWhatsAppWebhook(
      normalized,
      await sha256Hex(rawBody),
      correlationId
    );

    if (!result.knownChannel) {
      redactedFailure('WHATSAPP_WEBHOOK_CHANNEL_UNKNOWN', correlationId);
      return NextResponse.json({ status: 'ignored', correlationId }, { status: 200 });
    }

    return NextResponse.json(
      {
        status: 'accepted',
        correlationId,
        accepted: result.accepted,
        duplicates: result.duplicates,
        ignored: result.ignored,
      },
      { status: 200 }
    );
  } catch {
    redactedFailure('WHATSAPP_WEBHOOK_INGESTION_FAILED', correlationId);
    return NextResponse.json({ status: 'retry', correlationId }, { status: 500 });
  }
}
