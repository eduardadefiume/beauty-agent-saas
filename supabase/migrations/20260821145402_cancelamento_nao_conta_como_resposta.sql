-- Correção: mensagem cancelada não pode contar como resposta.
--
-- COMO APARECEU. Primeiro teste do agente com a chave da Anthropic no lugar: a
-- fila voltou vazia, sem erro nenhum. A conversa da Duda estava aberta, dentro
-- da janela, com a resposta automática ligada -- e mesmo assim o agente não a
-- via.
--
-- A CAUSA. A parada de emergência cancela a mensagem em app.outbox_messages,
-- mas a linha correspondente em app.crm_messages continua lá, OUTBOUND, com
-- deliveryStatus 'PENDING'. E list_conversations_awaiting_agent decide quem
-- está esperando olhando a ÚLTIMA mensagem da conversa. Uma mensagem que nunca
-- saiu passava a ser "a última", então a conversa saía da fila para sempre --
-- silenciosamente, que é o pior jeito de um sistema falhar.
--
-- O mesmo valia para a tela: mostrava "a caminho" uma mensagem que já tinha
-- sido cancelada.
--
-- DUAS CORREÇÕES, PORQUE UMA SÓ DEIXARIA O DADO VELHO ENVENENADO:
--
--   1. Cancelar passa a marcar também a crm_messages. A partir de agora o
--      histórico conta a verdade.
--   2. A fila passa a ignorar OUTBOUND cancelada ao decidir quem falou por
--      último. Isso conserta as conversas que já ficaram presas, e protege
--      contra qualquer outro caminho que venha a cancelar uma mensagem sem
--      lembrar de mexer no histórico.

-- ---------------------------------------------------------------------------
-- 1. Cancelar marca os dois lados.
-- ---------------------------------------------------------------------------
create or replace function public.site_set_agent_automation(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_enabled boolean,
  target_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_canceladas integer := 0;
  v_ids uuid[];
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  insert into app.agent_automation (tenant_id, enabled, changed_at, changed_by_email, reason)
  values (target_tenant_id, target_enabled, statement_timestamp(), target_email, left(target_reason, 500))
  on conflict (tenant_id) do update
    set enabled = excluded.enabled,
        changed_at = excluded.changed_at,
        changed_by_email = excluded.changed_by_email,
        reason = excluded.reason;

  if not target_enabled then
    -- Só PENDING: o que já está SENDING saiu do nosso alcance, e marcar como
    -- cancelado o que talvez já tenha sido entregue seria mentir no histórico.
    with canceladas as (
      update app.outbox_messages
         set status = 'CANCELLED', updated_at = statement_timestamp()
       where tenant_id = target_tenant_id
         and actor = 'AGENT'
         and status = 'PENDING'
      returning message_id
    )
    select array_agg(message_id) into v_ids from canceladas;

    v_canceladas := coalesce(array_length(v_ids, 1), 0);

    if v_canceladas > 0 then
      update app.crm_messages m
         set metadata_minimized = coalesce(m.metadata_minimized, '{}'::jsonb)
           || jsonb_build_object('deliveryStatus', 'CANCELLED')
       where m.tenant_id = target_tenant_id
         and m.id = any(v_ids);
    end if;
  end if;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id,
    correlation_id, result, metadata_minimized
  ) values (
    target_tenant_id, 'USER', null,
    case when target_enabled then 'AGENT_AUTOMATION_ENABLED' else 'AGENT_AUTOMATION_DISABLED' end,
    'agent_automation', target_tenant_id,
    'console-' || replace(gen_random_uuid()::text, '-', ''),
    'SUCCESS',
    jsonb_build_object('email', target_email, 'reason', target_reason, 'canceladas', v_canceladas)
  );

  return jsonb_build_object('ok', true, 'enabled', target_enabled, 'canceladas', v_canceladas);
end;
$function$;

grant execute on function public.site_set_agent_automation(text, text, uuid, boolean, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. A fila ignora o que foi cancelado.
--
-- O filtro entra no `where` da subconsulta, e não depois: o distinct on precisa
-- escolher a última mensagem QUE VALE, não descartar a conversa porque a última
-- linha da tabela era um cancelamento.
-- ---------------------------------------------------------------------------
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
     where coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
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
     and app.agent_automation_enabled(u.tenant_id)
   order by u.occurred_at
   limit p_limit;
$function$;

revoke all on function app.list_conversations_awaiting_agent(integer) from public, anon, authenticated;
grant execute on function app.list_conversations_awaiting_agent(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Conserta o histórico que já ficou mentindo.
-- ---------------------------------------------------------------------------
update app.crm_messages m
   set metadata_minimized = coalesce(m.metadata_minimized, '{}'::jsonb)
     || jsonb_build_object('deliveryStatus', 'CANCELLED')
  from app.outbox_messages o
 where o.message_id = m.id
   and o.status = 'CANCELLED'
   and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED';
