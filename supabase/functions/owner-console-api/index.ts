import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

// Owner console API — used by the self-hosted Next.js app (deployed by the
// owner, not by an intermediary platform). The Supabase project gateway
// verifies the caller's JWT before this function ever runs (verify_jwt =
// true at deploy time), so we only need to decode the already-verified
// token to read the caller's own authenticated email. There is no shared
// static secret to manage or rotate.

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

const ACTION_RPC = {
  list: 'site_list_tenants',
  load: 'site_load_configuration',
  save: 'site_replace_configuration',
  publish: 'site_publish_configuration',
} as const;

type Action = keyof typeof ACTION_RPC;

// Fixed namespace for this app in app.site_identities. There is exactly one
// deployment of the owner console, so this does not need to be configurable.
const SITE_PROJECT_ID = 'owner-console-v1';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function emailFromVerifiedJwt(authorizationHeader: string | null): string | null {
  if (!authorizationHeader?.startsWith('Bearer ')) return null;
  const token = authorizationHeader.slice('Bearer '.length);
  const segments = token.split('.');
  if (segments.length !== 3) return null;

  try {
    const base64 = segments[1].replace(/-/g, '+').replace(/_/g, '/');
    const payload = JSON.parse(atob(base64)) as { email?: unknown };
    return typeof payload.email === 'string' &&
      payload.email.length > 0 &&
      payload.email.length <= 320
      ? payload.email
      : null;
  } catch {
    return null;
  }
}

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') {
    return json(405, { error: 'METHOD_NOT_ALLOWED' });
  }

  const userEmail = emailFromVerifiedJwt(request.headers.get('authorization'));
  if (!userEmail) {
    return json(401, { error: 'UNAUTHENTICATED' });
  }

  const contentLength = Number(request.headers.get('content-length') ?? '0');
  if (contentLength > 262_144) {
    return json(413, { error: 'PAYLOAD_TOO_LARGE' });
  }

  let input: Record<string, unknown>;
  try {
    input = await request.json();
  } catch {
    return json(400, { error: 'INVALID_JSON' });
  }

  const action = input.action;
  const tenantId = input.tenantId;

  if (typeof action !== 'string' || !(action in ACTION_RPC)) {
    return json(400, { error: 'INVALID_REQUEST' });
  }
  if (action !== 'list' && typeof tenantId !== 'string') {
    return json(400, { error: 'TENANT_REQUIRED' });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !serviceRoleKey) {
    return json(503, { error: 'SERVICE_NOT_CONFIGURED' });
  }

  const common = {
    target_site_project_id: SITE_PROJECT_ID,
    target_email: userEmail,
  };
  let rpcBody: Record<string, unknown>;

  switch (action as Action) {
    case 'list':
      rpcBody = common;
      break;
    case 'load':
      rpcBody = { ...common, target_tenant_id: tenantId };
      break;
    case 'save':
      if (
        !Number.isInteger(input.expectedRevision) ||
        typeof input.payload !== 'object' ||
        input.payload === null
      ) {
        return json(400, { error: 'INVALID_SAVE_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        expected_revision: input.expectedRevision,
        payload: input.payload,
      };
      break;
    case 'publish':
      if (!Number.isInteger(input.expectedRevision)) {
        return json(400, { error: 'INVALID_PUBLISH_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        expected_revision: input.expectedRevision,
        target_correlation_id: crypto.randomUUID(),
      };
      break;
  }

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${ACTION_RPC[action as Action]}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      authorization: `Bearer ${serviceRoleKey}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(rpcBody),
  });

  if (!response.ok) {
    const failure = (await response.json().catch(() => ({}))) as {
      code?: string;
      message?: string;
    };
    const status =
      failure.code === '42501'
        ? 403
        : failure.code === '40001'
          ? 409
          : failure.code === '23514'
            ? 422
            : response.status >= 400 && response.status < 500
              ? response.status
              : 502;

    return json(status, {
      error: failure.message ?? 'DATABASE_REQUEST_FAILED',
      code: failure.code ?? null,
    });
  }

  return json(200, { data: await response.json() });
});
