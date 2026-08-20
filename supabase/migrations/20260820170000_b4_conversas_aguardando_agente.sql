-- B4 (parte 2): a fila do agente e o registro do que ele decidiu.
--
-- O contexto (parte 1) responde "o que o agente sabe sobre esta conversa".
-- Falta a pergunta anterior: "qual conversa ele deveria olhar agora?".
--
-- CINCO FILTROS, E CADA UM DESCARTA UM ERRO DIFERENTE:
--   1. A ultima mensagem e INBOUND -- se a ultima foi nossa, ninguem esta
--      esperando. Sem isso o agente responderia a propria resposta.
--   2. agentMayReply na ultima mensagem recebida -- a allowlist. Nas primeiras
--      semanas so um punhado de clientes tem resposta automatica; o resto e do
--      William, e o agente nao pode passar na frente dele.
--   3. Conversa OPEN -- conversa encerrada nao volta sozinha.
--   4. Janela de 24h aberta -- fora dela o envio seria recusado no
--      enfileiramento de qualquer jeito. Filtrar aqui evita gastar token de LLM
--      para produzir um texto que o banco vai recusar depois.
--   5. O agente ainda nao decidiu sobre esta mensagem -- ver abaixo.
--
-- POR QUE O FILTRO 5 EXISTE. Quando o agente decide passar a conversa para o
-- humano, ele nao envia nada. Sem marca nenhuma, a conversa continuaria com uma
-- INBOUND por ultimo e voltaria na proxima rodada, para sempre: uma chamada de
-- LLM por tick, indefinidamente, ate alguem responder. Marcar a decisao fecha
-- esse laco -- e de quebra deixa auditavel por que o agente calou.
--
-- ORDENADO PELO MAIS ANTIGO: quem esperou mais e atendido primeiro. Sob fila
-- cheia isso limita o pior caso de espera em vez do caso medio.

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

create or replace function public.list_conversations_awaiting_agent(
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
  select * from app.list_conversations_awaiting_agent(p_limit);
$function$;

revoke all on function public.list_conversations_awaiting_agent(integer) from public, anon, authenticated;
grant execute on function public.list_conversations_awaiting_agent(integer) to service_role;


-- Registro da decisao do agente sobre uma mensagem recebida.
--
-- Grava em metadata_minimized da propria mensagem, e nao numa tabela separada,
-- porque a decisao e um atributo daquela mensagem: "o que o agente fez quando
-- viu isto". Uma tabela a parte exigiria join em toda leitura de inbox para
-- responder a mesma pergunta.
--
-- So marca mensagem INBOUND que ainda nao tem decisao. A segunda chamada com o
-- mesmo id devolve ok/duplicate em vez de sobrescrever -- duas invocacoes
-- simultaneas do worker nao apagam uma a decisao da outra.
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


-- Fachada de enfileiramento recebendo o ator como texto.
--
-- app.enqueue_outbound_message tipa o ator como app.outbound_actor. Enum em
-- schema nao exposto nao atravessa o PostgREST: a Edge Function mandaria a
-- string 'AGENT' e receberia erro de tipo. A fachada recebe text e faz o cast
-- do lado de ca -- valor invalido continua estourando, so que na fronteira
-- certa.
create or replace function public.enqueue_outbound_message(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_body_text text,
  p_actor text,
  p_idempotency_key text,
  p_actor_user_id uuid default null
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select app.enqueue_outbound_message(
    p_tenant_id, p_conversation_id, p_body_text,
    p_actor::app.outbound_actor, p_idempotency_key, p_actor_user_id
  );
$function$;

revoke all on function public.enqueue_outbound_message(uuid, uuid, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.enqueue_outbound_message(uuid, uuid, text, text, text, uuid) to service_role;

comment on function app.list_conversations_awaiting_agent(integer) is
  'B4: conversas cuja ultima mensagem e da cliente, com resposta automatica autorizada, ainda sem decisao do agente, abertas e dentro da janela de 24h. Mais antiga primeiro.';
comment on function app.mark_agent_decision(uuid, uuid, text, text) is
  'B4: registra na mensagem recebida o que o agente decidiu (REPLY/HANDOFF/ERROR). Fecha o laco que faria o agente reprocessar para sempre uma conversa que ele decidiu nao responder.';
