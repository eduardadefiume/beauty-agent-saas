-- O console ganha a fila de perguntas do agente.
--
-- Fica no mesmo retorno das conversas de propósito: é a primeira coisa que a
-- dona precisa ver ao abrir a tela, porque cada pergunta parada ali é uma
-- cliente em espera sem saber que está esperando.
create or replace function public.site_whatsapp_console(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_limite integer := least(greatest(coalesce(target_limit, 20), 1), 50);
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  return jsonb_build_object(
    'automation', coalesce((
      select jsonb_build_object(
        'enabled', a.enabled,
        'changedAt', a.changed_at,
        'changedByEmail', a.changed_by_email,
        'reason', a.reason
      ) from app.agent_automation a where a.tenant_id = target_tenant_id
    ), jsonb_build_object('enabled', false, 'changedAt', null, 'changedByEmail', null, 'reason', null)),

    'connection', coalesce((
      select jsonb_build_object(
        'id', c.id, 'channel', c.channel, 'senderId', c.external_sender_id,
        'mode', c.mode, 'status', c.status, 'lastWebhookAt', c.last_webhook_at
      )
      from app.channel_connections c
      where c.tenant_id = target_tenant_id and c.channel = 'WHATSAPP'
      order by c.created_at desc limit 1
    ), 'null'::jsonb),

    'ownerQuestions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', q.id,
        'conversationId', q.conversation_id,
        'contactName', ct.display_name,
        'whatsapp', ch.address_normalized,
        'question', q.question,
        'contextSummary', q.context_summary,
        'createdAt', q.created_at,
        'waitingSeconds', extract(epoch from (statement_timestamp() - q.created_at))::integer
      ) order by q.created_at)
      from app.agent_owner_questions q
      join app.crm_conversations cv on cv.tenant_id = q.tenant_id and cv.id = q.conversation_id
      join app.crm_contacts ct on ct.tenant_id = cv.tenant_id and ct.id = cv.contact_id
      left join app.crm_contact_channels ch
        on ch.tenant_id = cv.tenant_id and ch.contact_id = cv.contact_id and ch.provider = 'WHATSAPP'
     where q.tenant_id = target_tenant_id and q.status = 'PENDING'
    ), '[]'::jsonb),

    'counters', jsonb_build_object(
      'conversationsOpen', (
        select count(*) from app.crm_conversations c
         where c.tenant_id = target_tenant_id and c.status = 'OPEN'),
      'windowOpen', (
        select count(*) from app.crm_conversations c
         where c.tenant_id = target_tenant_id and c.status = 'OPEN'
           and c.last_inbound_at > (statement_timestamp() - interval '24 hours')),
      'messages24h', (
        select count(*) from app.crm_messages m
         where m.tenant_id = target_tenant_id
           and m.occurred_at > (statement_timestamp() - interval '24 hours')),
      'outboxPending', (
        select count(*) from app.outbox_messages o
         where o.tenant_id = target_tenant_id and o.status in ('PENDING', 'SENDING')),
      'outboxFailed', (
        select count(*) from app.outbox_messages o
         where o.tenant_id = target_tenant_id and o.status = 'FAILED'),
      'agentReplies24h', (
        select count(*) from app.crm_messages m
         where m.tenant_id = target_tenant_id
           and m.direction = 'OUTBOUND'
           and m.metadata_minimized->>'actor' = 'AGENT'
           and m.occurred_at > (statement_timestamp() - interval '24 hours')),
      'ownerQuestionsPending', (
        select count(*) from app.agent_owner_questions q
         where q.tenant_id = target_tenant_id and q.status = 'PENDING'),
      'handoffs24h', (
        select count(*) from app.crm_messages m
         where m.tenant_id = target_tenant_id
           and m.metadata_minimized->>'agentDecision' = 'HANDOFF'
           and m.occurred_at > (statement_timestamp() - interval '24 hours'))
    ),

    'conversations', coalesce((
      select jsonb_agg(linha order by linha->>'lastMessageAt' desc)
      from (
        select jsonb_build_object(
          'id', c.id,
          'status', c.status,
          'contactName', ct.display_name,
          'whatsapp', ch.address_normalized,
          'lastMessageAt', c.last_message_at,
          'lastInboundAt', c.last_inbound_at,
          'windowOpen', c.last_inbound_at is not null
                        and c.last_inbound_at > (statement_timestamp() - interval '24 hours'),
          'minutesRemaining', case
            when c.last_inbound_at is null then 0
            else greatest(0, extract(epoch from (
              c.last_inbound_at + interval '24 hours' - statement_timestamp()))::integer / 60)
          end,
          'messages', coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', m.id,
              'direction', m.direction,
              'text', m.body_text,
              'at', m.occurred_at,
              'actor', m.metadata_minimized->>'actor',
              'deliveryStatus', m.metadata_minimized->>'deliveryStatus',
              'agentMayReply', (m.metadata_minimized->>'agentMayReply')::boolean,
              'agentDecision', m.metadata_minimized->>'agentDecision',
              'agentDecisionReason', m.metadata_minimized->>'agentDecisionReason'
            ) order by h.occurred_at)
            from (
              select m2.id, m2.occurred_at
                from app.crm_messages m2
               where m2.tenant_id = c.tenant_id and m2.conversation_id = c.id
               order by m2.occurred_at desc limit 30
            ) h
            join app.crm_messages m on m.id = h.id
          ), '[]'::jsonb)
        ) as linha
        from app.crm_conversations c
        join app.crm_contacts ct on ct.tenant_id = c.tenant_id and ct.id = c.contact_id
        left join app.crm_contact_channels ch
          on ch.tenant_id = c.tenant_id and ch.contact_id = c.contact_id and ch.provider = 'WHATSAPP'
       where c.tenant_id = target_tenant_id
       order by c.last_message_at desc nulls last
       limit v_limite
      ) conversas
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_whatsapp_console(text, text, uuid, integer) to service_role;