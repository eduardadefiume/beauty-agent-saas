import { createSupabaseServerClient } from '../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

// Proxy da tela de Histórico: o arquivo das conversas do WhatsApp do dono.
const ACTIONS = new Set([
  'waArchives',
  'waArchiveAdd',
  'waArchiveRead',
  'waSetOwnerLabel',
  'forgetContactHistory',
]);

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export async function POST(request: Request): Promise<Response> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session?.access_token) {
    return json(401, { error: 'AUTHENTICATION_REQUIRED' });
  }

  const endpoint = process.env.SUPABASE_CONFIGURATOR_URL;
  if (!endpoint) {
    return json(503, { error: 'CONFIGURATOR_NOT_AVAILABLE' });
  }

  const contentLength = Number(request.headers.get('content-length') ?? '0');
  if (contentLength > 65_536) {
    return json(413, { error: 'PAYLOAD_TOO_LARGE' });
  }

  let input: Record<string, unknown>;
  try {
    input = (await request.json()) as Record<string, unknown>;
  } catch {
    return json(400, { error: 'INVALID_JSON' });
  }

  if (typeof input.action !== 'string' || !ACTIONS.has(input.action)) {
    return json(400, { error: 'INVALID_ACTION' });
  }
  if (typeof input.tenantId !== 'string') {
    return json(400, { error: 'TENANT_REQUIRED' });
  }

  const upstream = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      action: input.action,
      tenantId: input.tenantId,
      storagePath: input.storagePath,
      filename: input.filename,
      contactLabel: input.contactLabel,
      phoneDigits: input.phoneDigits,
      archiveId: input.archiveId,
      contactId: input.contactId,
      ownerLabel: input.ownerLabel,
      offset: input.offset,
      limit: input.limit,
    }),
  });

  const responseBody = await upstream.json().catch(() => ({ error: 'INVALID_UPSTREAM_RESPONSE' }));
  return json(upstream.status, responseBody);
}
