import { createSupabaseServerClient } from '../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

// Proxy do console de WhatsApp.
//
// Rota própria em vez de mais duas ações em /api/configuration porque aquele
// proxy repassa uma lista fixa de campos (expectedRevision, payload,
// connectionId) e nada mais. Encaixar `enabled` e `limit` lá significaria mexer
// no caminho por onde passa a publicação da configuração — risco desnecessário
// para ganhar um arquivo a menos.
//
// A sessão do Supabase é lida no servidor e o JWT do usuário vai para a Edge
// Function, que resolve o tenant a partir do e-mail assinado. O navegador nunca
// escolhe em nome de quem age.
const ACTIONS = new Set([
  'whatsappConsole',
  'setAgentAutomation',
  'answerOwnerQuestion',
  'dismissOwnerQuestion',
  'agentParkedConversations',
  'resumeParkedConversation',
  'sendMessage',
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
  // `enabled` só vale como booleano. A Edge Function repete o cheque; repetir
  // aqui é o que faz um "false" em texto morrer antes de virar um agente ligado.
  if (input.action === 'setAgentAutomation' && typeof input.enabled !== 'boolean') {
    return json(400, { error: 'INVALID_AUTOMATION_REQUEST' });
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
      enabled: typeof input.enabled === 'boolean' ? input.enabled : undefined,
      reason: typeof input.reason === 'string' ? input.reason : undefined,
      questionId: typeof input.questionId === 'string' ? input.questionId : undefined,
      answer: typeof input.answer === 'string' ? input.answer : undefined,
      conversationId: typeof input.conversationId === 'string' ? input.conversationId : undefined,
      text: typeof input.text === 'string' ? input.text : undefined,
      idempotencyKey: typeof input.idempotencyKey === 'string' ? input.idempotencyKey : undefined,
    }),
  });

  const responseBody = await upstream.json().catch(() => ({ error: 'INVALID_UPSTREAM_RESPONSE' }));
  return json(upstream.status, responseBody);
}
