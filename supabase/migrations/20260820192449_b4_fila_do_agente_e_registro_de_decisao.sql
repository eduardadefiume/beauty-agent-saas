create or replace function app.list_conversations_awaiting_agent(
  p_limit integer default 20
)
returns table (
  conversation_id uuid,
  tenant_id uuid,
  last_inbound_message_id uuid,
  waiting_seconds integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  with ultima as (
    select distinct on (m.tenant_id, m.conversation_id)
           m.tenant_id, m.conversation_id, m.id as message_id,
           m.direction, m.occurred_at,
           coalesce((m.metadata_minimized->>'agentMayReply')::boolean, false) as pode_responder,
           (m.metadata_minimized ? 'agentDecision') as ja_decidido
      from app.crm_messages m
     order by m.tenant_id, m.conversation_id, m.occurred_at desc
  )
  select u.conversation_id, u.tenant_id, u.message_id,
         extract(epoch from (statement_timestamp() - u.occurred_at))::integer
    from ultima u
    join app.crm_conversations c
      on c.tenant_id = u.tenant_id and c.id = u.conversation_id
   where u.direction = 'INBOUND'
     and u.pode_responder
     and not u.ja_decidido
     and c.status = 'OPEN'
     and c.last_inbound_at > (statement_timestamp() - interval '24 hours')
   order by u.occurred_at
   limit p_limit;
$function$;

revoke all on function app.list_conversations_awaiting_agent(integer) from public, anon, authenticated;
grant execute on function app.list_conversations_awaiting_agent(integer) to service_role;

revoke all on function public.list_conversations_awaiting_agent(integer) from public, anon, authenticated;
grant execute on function public.list_conversations_awaiting_agent(integer) to service_role;

create or replace function app.mark_agent_decision(
  p_tenant_id uuid,
  p_message_id uuid,
  p_decision text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_atualizadas integer;
begin
  if p_decision is null or p_decision not in ('REPLY', 'HANDOFF', 'ERROR') then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_DECISION');
  end if;

  update app.crm_messages m
     set metadata_minimized = coalesce(m.metadata_minimized, '{}'::jsonb)
       || jsonb_build_object(
            'agentDecision', p_decision,
            'agentDecisionReason', left(coalesce(p_reason, ''), 500),
            'agentDecidedAt', to_char(statement_timestamp() at time zone 'UTC',
                                      'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          )
   where m.tenant_id = p_tenant_id
     and m.id = p_message_id
     and m.direction = 'INBOUND'
     and not (coalesce(m.metadata_minimized, '{}'::jsonb) ? 'agentDecision');

  get diagnostics v_atualizadas = row_count;

  if v_atualizadas = 0 then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false);
end;
$function$;

revoke all on function app.mark_agent_decision(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function app.mark_agent_decision(uuid, uuid, text, text) to service_role;

create or replace function public.mark_agent_decision(
  p_tenant_id uuid,
  p_message_id uuid,
  p_decision text,
  p_reason text default null
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select app.mark_agent_decision(p_tenant_id, p_message_id, p_decision, p_reason);
$function$;

revoke all on function public.mark_agent_decision(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.mark_agent_decision(uuid, uuid, text, text) to service_role;

comment on function app.list_conversations_awaiting_agent(integer) is
  'B4: conversas cuja ultima mensagem e da cliente, com resposta automatica autorizada, ainda sem decisao do agente, abertas e dentro da janela de 24h. Mais antiga primeiro.';
comment on function app.mark_agent_decision(uuid, uuid, text, text) is
  'B4: registra na mensagem recebida o que o agente decidiu (REPLY/HANDOFF/ERROR). Fecha o laco que faria o agente reprocessar para sempre uma conversa que ele decidiu nao responder.';