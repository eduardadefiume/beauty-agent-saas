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
  startNewDraft: 'site_start_new_draft',
  listCalendarConnections: 'site_list_calendar_connections',
  saveCalendarConnection: 'site_save_calendar_connection',
  disconnectCalendarConnection: 'site_disconnect_calendar_connection',
  listCalendarShifts: 'site_list_calendar_shifts',
  listCalendarConnectionsForSync: 'site_list_calendar_connections_for_sync',
  recordCalendarShiftSync: 'site_record_calendar_shift_sync',
  // Console de WhatsApp: o que a dona vê acontecendo e o botão que desliga a
  // resposta automática.
  whatsappConsole: 'site_whatsapp_console',
  setAgentAutomation: 'site_set_agent_automation',
  answerOwnerQuestion: 'site_answer_owner_question',
  dismissOwnerQuestion: 'site_dismiss_owner_question',
  // Conversas que o agente desistiu de atender depois de tropecar cinco vezes.
  // Existem como acao propria, e nao dentro do console, porque estacionar uma
  // conversa e deixar uma cliente sem resposta: precisa de um lugar onde uma
  // pessoa veja e resolva, nao de um numero no meio de outros.
  agentParkedConversations: 'site_agent_parked_conversations',
  resumeParkedConversation: 'site_resume_parked_conversation',
  // O dono respondendo pela tela. Existe porque um numero na Cloud API sai do
  // aplicativo do WhatsApp Business: sem esta acao, no dia da migracao o dono
  // fica sem nenhuma forma de falar com a cliente dele.
  sendMessage: 'site_send_manual_message',
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
    case 'startNewDraft':
      // Depois de publicar, a configuração fica congelada — esta ação clona
      // o último publicado para um rascunho novo editável (ou devolve o
      // rascunho já aberto, se já existir um; idempotente na própria RPC).
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_correlation_id: crypto.randomUUID(),
      };
      break;
    case 'listCalendarConnections':
      rpcBody = { ...common, target_tenant_id: tenantId };
      break;
    case 'saveCalendarConnection':
      // Só chamada pela rota /auth/google-calendar/callback, server-to-server
      // — o token nunca passa pelo navegador. Ver validação lá.
      if (typeof input.provider !== 'string' || typeof input.accessToken !== 'string') {
        return json(400, { error: 'INVALID_SAVE_CALENDAR_CONNECTION_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_provider: input.provider,
        target_member_name: typeof input.memberName === 'string' ? input.memberName : null,
        target_external_account_email:
          typeof input.externalAccountEmail === 'string' ? input.externalAccountEmail : null,
        target_calendar_id: typeof input.calendarId === 'string' ? input.calendarId : 'primary',
        target_access_token: input.accessToken,
        target_refresh_token: typeof input.refreshToken === 'string' ? input.refreshToken : null,
        target_token_expires_at:
          typeof input.tokenExpiresAt === 'string' ? input.tokenExpiresAt : null,
        target_scope: typeof input.scope === 'string' ? input.scope : null,
      };
      break;
    case 'disconnectCalendarConnection':
      if (typeof input.connectionId !== 'string') {
        return json(400, { error: 'INVALID_DISCONNECT_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_connection_id: input.connectionId,
      };
      break;
    case 'listCalendarShifts':
      rpcBody = { ...common, target_tenant_id: tenantId };
      break;
    case 'listCalendarConnectionsForSync':
      // Devolve token de acesso/atualização — só a rota /api/calendar-sync
      // chama esta ação, nunca o proxy genérico usado pelo navegador
      // (/api/configuration não inclui isso no ACTIONS dela).
      rpcBody = { ...common, target_tenant_id: tenantId };
      break;
    case 'recordCalendarShiftSync':
      if (
        typeof input.connectionId !== 'string' ||
        typeof input.windowStart !== 'string' ||
        typeof input.windowEnd !== 'string' ||
        !Array.isArray(input.events)
      ) {
        return json(400, { error: 'INVALID_RECORD_SYNC_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_connection_id: input.connectionId,
        target_window_start: input.windowStart,
        target_window_end: input.windowEnd,
        target_events: input.events,
        target_new_access_token:
          typeof input.newAccessToken === 'string' ? input.newAccessToken : null,
        target_new_token_expires_at:
          typeof input.newTokenExpiresAt === 'string' ? input.newTokenExpiresAt : null,
        target_error: typeof input.syncError === 'string' ? input.syncError : null,
      };
      break;
    case 'whatsappConsole':
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_limit: Number.isInteger(input.limit) ? input.limit : 20,
      };
      break;
    case 'setAgentAutomation':
      // `enabled` tem que vir booleano de verdade. Aceitar "false" em texto
      // aqui seria aceitar que um erro de digitação ligue o agente.
      if (typeof input.enabled !== 'boolean') {
        return json(400, { error: 'INVALID_AUTOMATION_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_enabled: input.enabled,
        target_reason: typeof input.reason === 'string' ? input.reason : null,
      };
      break;
    case 'answerOwnerQuestion':
      if (typeof input.questionId !== 'string' || typeof input.answer !== 'string') {
        return json(400, { error: 'INVALID_ANSWER_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_question_id: input.questionId,
        target_answer: input.answer,
      };
      break;
    case 'dismissOwnerQuestion':
      if (typeof input.questionId !== 'string') {
        return json(400, { error: 'INVALID_DISMISS_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_question_id: input.questionId,
      };
      break;
    case 'agentParkedConversations':
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_limit: Number.isInteger(input.limit) ? input.limit : 50,
      };
      break;
    case 'resumeParkedConversation':
      if (typeof input.conversationId !== 'string') {
        return json(400, { error: 'INVALID_RESUME_REQUEST' });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        target_conversation_id: input.conversationId,
      };
      break;
    case 'sendMessage':
      // A chave de idempotencia vem do navegador de proposito: se a conexao
      // cair depois do envio e a pessoa apertar de novo, a mesma chave devolve
      // o mesmo envio em vez de mandar duas vezes para a cliente.
      {
        const temAnexo =
          typeof input.mediaStoragePath === 'string' && input.mediaStoragePath.length > 0;
        const texto = typeof input.text === 'string' ? input.text : '';
        // Audio nao vem com legenda. Exigir texto aqui impediria mandar audio,
        // que e metade da conversa de um salao.
        if (
          typeof input.conversationId !== 'string' ||
          (texto.trim().length === 0 && !temAnexo) ||
          (temAnexo && typeof input.mediaMimeType !== 'string') ||
          typeof input.idempotencyKey !== 'string' ||
          input.idempotencyKey.length < 8 ||
          input.idempotencyKey.length > 128
        ) {
          return json(400, { error: 'INVALID_SEND_REQUEST' });
        }
        rpcBody = {
          ...common,
          target_tenant_id: tenantId,
          target_conversation_id: input.conversationId,
          message_text: texto,
          idempotency_key: input.idempotencyKey,
          media_storage_path: temAnexo ? input.mediaStoragePath : null,
          media_mime_type: temAnexo ? input.mediaMimeType : null,
          media_filename: typeof input.mediaFilename === 'string' ? input.mediaFilename : null,
        };
      }
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
