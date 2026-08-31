import { createSupabaseServerClient } from '../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

// Proxy da tela de Clientes.
//
// Rota própria, como /api/whatsapp, e pelo mesmo motivo: /api/configuration
// repassa uma lista fixa de campos ligada à publicação da configuração. Ficha
// de cliente não é configuração — não entra no ciclo de rascunho, não trava
// quando o negócio está publicado — então não passa por lá.
//
// A sessão é lida no servidor e o JWT do usuário vai para a Edge Function, que
// resolve a identidade a partir do e-mail assinado. O navegador nunca escolhe
// em nome de quem age.
const ACTIONS = new Set(['loadClients', 'loadClient', 'saveClient']);

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
  if (contentLength > 262_144) {
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
      limit: typeof input.limit === 'number' ? input.limit : undefined,
      profileId: typeof input.profileId === 'string' ? input.profileId : undefined,
      payload: input.payload,
    }),
  });

  const responseBody = await upstream.json().catch(() => ({ error: 'INVALID_UPSTREAM_RESPONSE' }));
  return json(upstream.status, responseBody);
}
