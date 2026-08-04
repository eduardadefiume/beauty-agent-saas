import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

const jsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
};

type IntentRequest = {
  tenantId: string;
  correlationId: string;
  message: string;
};

function response(req: Request, body: unknown, status: number): Response {
  const allowedOrigin = Deno.env.get('APP_ORIGIN') ?? '';
  const origin = req.headers.get('origin');
  const corsHeaders =
    origin && origin === allowedOrigin
      ? {
          'Access-Control-Allow-Origin': origin,
          Vary: 'Origin',
        }
      : {};

  return new Response(JSON.stringify(body), {
    status,
    headers: { ...jsonHeaders, ...corsHeaders },
  });
}

function isUuid(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  );
}

function isRequest(value: unknown): value is IntentRequest {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Record<string, unknown>;

  return (
    isUuid(candidate.tenantId) &&
    typeof candidate.correlationId === 'string' &&
    candidate.correlationId.length >= 8 &&
    candidate.correlationId.length <= 128 &&
    typeof candidate.message === 'string' &&
    candidate.message.trim().length >= 1 &&
    candidate.message.length <= 4000
  );
}

function readPublishableKey(): string {
  const keys = JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') ?? '{}') as Record<
    string,
    string
  >;
  const key = keys.default;

  if (!key) throw new Error('SUPABASE_PUBLISHABLE_KEY_MISSING');
  return key;
}

async function safetyIdentifier(userId: string, tenantId: string): Promise<string> {
  const bytes = new TextEncoder().encode(`${userId}:${tenantId}`);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest))
    .map((part) => part.toString(16).padStart(2, '0'))
    .join('');
}

function extractOutputText(payload: Record<string, unknown>): string | null {
  const output = Array.isArray(payload.output) ? payload.output : [];

  for (const item of output) {
    if (!item || typeof item !== 'object') continue;
    const content = Array.isArray((item as Record<string, unknown>).content)
      ? ((item as Record<string, unknown>).content as unknown[])
      : [];

    for (const part of content) {
      if (
        part &&
        typeof part === 'object' &&
        (part as Record<string, unknown>).type === 'output_text' &&
        typeof (part as Record<string, unknown>).text === 'string'
      ) {
        return (part as Record<string, unknown>).text as string;
      }
    }
  }

  return null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const allowedOrigin = Deno.env.get('APP_ORIGIN') ?? '';
  const origin = req.headers.get('origin');

  if (origin && origin !== allowedOrigin) {
    return response(req, { code: 'ORIGIN_NOT_ALLOWED' }, 403);
  }

  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': origin ?? allowedOrigin,
        'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        Vary: 'Origin',
      },
    });
  }

  if (req.method !== 'POST') {
    return response(req, { code: 'METHOD_NOT_ALLOWED' }, 405);
  }

  const authorization = req.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ')) {
    return response(req, { code: 'AUTHENTICATION_REQUIRED' }, 401);
  }

  let input: unknown;
  try {
    input = await req.json();
  } catch {
    return response(req, { code: 'INVALID_JSON' }, 400);
  }

  if (!isRequest(input)) {
    return response(req, { code: 'INVALID_INTENT_REQUEST' }, 400);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const openaiKey = Deno.env.get('OPENAI_API_KEY');
  const openaiModel = Deno.env.get('OPENAI_MODEL') ?? 'gpt-5.6-sol';

  if (!supabaseUrl || !openaiKey) {
    return response(req, { code: 'INTEGRATION_NOT_CONFIGURED' }, 503);
  }

  let publishableKey: string;
  try {
    publishableKey = readPublishableKey();
  } catch {
    return response(req, { code: 'INTEGRATION_NOT_CONFIGURED' }, 503);
  }

  const authHeaders = {
    apikey: publishableKey,
    Authorization: authorization,
    'Content-Type': 'application/json',
  };

  const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: authHeaders,
  });

  if (!userResponse.ok) {
    return response(req, { code: 'INVALID_SESSION' }, 401);
  }

  const user = (await userResponse.json()) as { id?: string };
  if (!isUuid(user.id)) {
    return response(req, { code: 'INVALID_SESSION' }, 401);
  }

  const tenantAccessResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/can_access_tenant`, {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify({ target_tenant_id: input.tenantId }),
  });

  if (!tenantAccessResponse.ok || (await tenantAccessResponse.json()) !== true) {
    return response(req, { code: 'TENANT_ACCESS_DENIED' }, 403);
  }

  const schema = {
    type: 'object',
    additionalProperties: false,
    required: [
      'intent',
      'serviceQuery',
      'preferredDate',
      'preferredPeriod',
      'customerName',
      'needsClarification',
      'missingFields',
    ],
    properties: {
      intent: {
        type: 'string',
        enum: ['BOOK', 'RESCHEDULE', 'CANCEL', 'INFO', 'HUMAN_HANDOFF', 'UNKNOWN'],
      },
      serviceQuery: { type: ['string', 'null'] },
      preferredDate: {
        type: ['string', 'null'],
        description: 'ISO date YYYY-MM-DD only when explicitly inferable from the message.',
      },
      preferredPeriod: {
        enum: ['MORNING', 'AFTERNOON', 'EVENING', null],
      },
      customerName: { type: ['string', 'null'] },
      needsClarification: { type: 'boolean' },
      missingFields: {
        type: 'array',
        items: {
          type: 'string',
          enum: ['SERVICE', 'DATE', 'PERIOD', 'CUSTOMER_NAME', 'CURRENT_BOOKING', 'OTHER'],
        },
      },
    },
  } as const;

  const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${openaiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: openaiModel,
      store: false,
      safety_identifier: await safetyIdentifier(user.id, input.tenantId),
      reasoning: { effort: 'low' },
      input: [
        {
          role: 'developer',
          content: [
            {
              type: 'input_text',
              text: 'Extraia intenção e dados de agendamento em português do Brasil. Não calcule disponibilidade, duração, preço, política ou confirmação. Não invente dados ausentes. Quando faltar algo necessário, marque needsClarification e liste missingFields.',
            },
          ],
        },
        {
          role: 'user',
          content: [{ type: 'input_text', text: input.message.trim() }],
        },
      ],
      text: {
        verbosity: 'low',
        format: {
          type: 'json_schema',
          name: 'booking_intent',
          strict: true,
          schema,
        },
      },
      max_output_tokens: 500,
    }),
  });

  if (!openaiResponse.ok) {
    console.error(
      JSON.stringify({
        event: 'openai_intent_failed',
        correlationId: input.correlationId,
        status: openaiResponse.status,
      })
    );
    return response(req, { code: 'OPENAI_UNAVAILABLE', correlationId: input.correlationId }, 503);
  }

  const openaiPayload = (await openaiResponse.json()) as Record<string, unknown>;
  const outputText = extractOutputText(openaiPayload);

  if (!outputText) {
    return response(
      req,
      { code: 'OPENAI_INVALID_OUTPUT', correlationId: input.correlationId },
      502
    );
  }

  let interpretation: unknown;
  try {
    interpretation = JSON.parse(outputText);
  } catch {
    return response(
      req,
      { code: 'OPENAI_INVALID_OUTPUT', correlationId: input.correlationId },
      502
    );
  }

  console.log(
    JSON.stringify({
      event: 'openai_intent_succeeded',
      correlationId: input.correlationId,
      tenantId: input.tenantId,
      model: openaiModel,
    })
  );

  return response(
    req,
    {
      correlationId: input.correlationId,
      model: openaiModel,
      interpretation,
    },
    200
  );
});
