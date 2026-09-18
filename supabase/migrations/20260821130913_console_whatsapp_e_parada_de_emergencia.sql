-- Console de WhatsApp e a parada de emergência.
--
-- POR QUE ISTO EXISTE. Até agora o agente só podia ser observado por quem sabe
-- ler tabela do Postgres. A Duda pediu o contrário: ver o que está acontecendo
-- em tempo real e ter um botão que desliga a resposta automática na hora, sem
-- depender de mim. Enquanto não existir esse botão, ligar o agente para uma
-- cliente de verdade é apostar.
--
-- A CHAVE GERAL NASCE DESLIGADA. `enabled` tem default false e a ausência de
-- linha também conta como desligado. O agente não responde ninguém até alguém
-- ligar de propósito -- que é o comportamento certo para um sistema que fala
-- com cliente em nome do salão.
--
-- O QUE "PARADA DE EMERGÊNCIA" PRECISA SIGNIFICAR PARA VALER O NOME. Três
-- coisas, e as três estão aqui:
--
--   1. A fila do agente seca. list_conversations_awaiting_agent não devolve
--      nada para tenant desligado, então o próximo tique do worker não tem o
--      que fazer.
--   2. A janela entre "worker já pegou a conversa" e "worker vai enfileirar"
--      fecha. enqueue_outbound_message recusa ator AGENT com a chave desligada.
--      Sem isso, um lote que já estava no meio da chamada ao modelo ainda
--      mandaria mensagem depois do clique.
--   3. O que já está na fila de saída não sai. Mensagens PENDING do agente são
--      canceladas no ato de desligar. Botão de parada que deixa três mensagens
--      escaparem não é botão de parada.
--
-- O QUE ELE NÃO FAZ, DE PROPÓSITO: não bloqueia envio humano. O William tem
-- que continuar respondendo à vontade, com o agente ligado ou desligado --
-- essa é a premissa do produto inteiro. Só o ator AGENT é barrado.

create table if not exists app.agent_automation (
  tenant_id        uuid primary key references app.tenants(id) on delete cascade,
  enabled          boolean not null default false,
  changed_at       timestamptz not null default statement_timestamp(),
  changed_by_email text,
  reason           text
);

comment on table app.agent_automation is
  'Chave geral da resposta automática por tenant. Ausência de linha = desligado.';

-- Uma linha por tenant existente, desligada. Estado explícito lê melhor que
-- ausência de linha na hora de mostrar na tela.
insert into app.agent_automation (tenant_id, enabled, reason)
select t.id, false, 'Estado inicial: resposta automática nasce desligada.'
  from app.tenants t
 where not exists (select 1 from app.agent_automation a where a.tenant_id = t.id);


create or replace function app.agent_automation_enabled(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce((
    select a.enabled from app.agent_automation a where a.tenant_id = p_tenant_id
  ), false);
$function$;

revoke all on function app.agent_automation_enabled(uuid) from public, anon, authenticated;
grant execute on function app.agent_automation_enabled(uuid) to service_role;


-- ---------------------------------------------------------------------------
-- Barreira 1: a fila seca.
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
-- Barreira 2: o enfileiramento recusa o agente com a chave desligada.
--
-- Recriada inteira porque CREATE OR REPLACE não aceita alteração parcial de
-- corpo. O que mudou em relação à versão do B3 são as sete linhas do bloco
-- AGENT_AUTOMATION_DISABLED, logo após a validação da chave de idempotência.
-- ---------------------------------------------------------------------------
create or replace function app.enqueue_outbound_message(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_body_text text,
  p_actor app.outbound_actor,
  p_idempotency_key text,
  p_actor_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_conversa record;
  v_endereco text;
  v_janela_aberta boolean;
  v_message_id uuid;
  v_outbox_id uuid;
  v_existente record;
begin
  if p_body_text is null or length(trim(p_body_text)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_BODY');
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 8 and 128 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_IDEMPOTENCY_KEY');
  end if;

  -- Só o agente é barrado. Envio humano passa com a chave desligada -- é o
  -- ponto todo: a parada de emergência cala o robô, não o salão.
  if p_actor = 'AGENT' and not app.agent_automation_enabled(p_tenant_id) then
    return jsonb_build_object('ok', false, 'reason', 'AGENT_AUTOMATION_DISABLED');
  end if;

  select o.id, o.message_id, o.status into v_existente
    from app.outbox_messages o
   where o.tenant_id = p_tenant_id
     and o.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'ok', true, 'duplicate', true,
      'outboxId', v_existente.id, 'messageId', v_existente.message_id,
      'status', v_existente.status
    );
  end if;

  select c.*, ch.address_normalized
    into v_conversa
    from app.crm_conversations c
    join app.crm_contact_channels ch
      on ch.tenant_id = c.tenant_id
     and ch.contact_id = c.contact_id
     and ch.provider = 'WHATSAPP'
   where c.tenant_id = p_tenant_id
     and c.id = p_conversation_id
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSATION_NOT_FOUND');
  end if;

  v_endereco := v_conversa.address_normalized;

  v_janela_aberta := v_conversa.last_inbound_at is not null
    and v_conversa.last_inbound_at > (statement_timestamp() - interval '24 hours');

  if not v_janela_aberta then
    return jsonb_build_object(
      'ok', false,
      'reason', 'SERVICE_WINDOW_CLOSED',
      'lastInboundAt', v_conversa.last_inbound_at,
      'hint', 'Fora da janela de 24h so e possivel reabrir com template aprovado.'
    );
  end if;

  insert into app.crm_messages (
    tenant_id, conversation_id, direction, provider_message_id,
    message_type, body_text, occurred_at, metadata_minimized
  )
  values (
    p_tenant_id, p_conversation_id, 'OUTBOUND', null,
    'TEXT', left(p_body_text, 4096), statement_timestamp(),
    jsonb_build_object('actor', p_actor, 'deliveryStatus', 'PENDING')
  )
  returning id into v_message_id;

  insert into app.outbox_messages (
    tenant_id, conversation_id, message_id, channel_connection_id,
    recipient_address, kind, body_text, actor, actor_user_id, idempotency_key
  )
  values (
    p_tenant_id, p_conversation_id, v_message_id, v_conversa.channel_connection_id,
    v_endereco, 'TEXT', left(p_body_text, 4096), p_actor, p_actor_user_id,
    trim(p_idempotency_key)
  )
  returning id into v_outbox_id;

  update app.crm_conversations
     set last_message_at = greatest(last_message_at, statement_timestamp()),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id and id = p_conversation_id;

  return jsonb_build_object(
    'ok', true, 'duplicate', false,
    'outboxId', v_outbox_id, 'messageId', v_message_id, 'recipient', v_endereco
  );
end;
$function$;

revoke all on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid) from public, anon, authenticated;
grant execute on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid) to service_role;


-- ---------------------------------------------------------------------------
-- O botão.
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

  -- Barreira 3. Só PENDING: o que já está SENDING saiu do nosso alcance, e
  -- marcar como cancelado o que talvez já tenha sido entregue seria mentir no
  -- histórico.
  if not target_enabled then
    update app.outbox_messages
       set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = target_tenant_id
       and actor = 'AGENT'
       and status = 'PENDING';
    get diagnostics v_canceladas = row_count;
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
-- O que a tela mostra.
--
-- Uma chamada só devolve tudo: estado da chave, saúde da conexão, contadores e
-- as conversas com as últimas mensagens. A tela recarrega isto a cada poucos
-- segundos, então dividir em cinco chamadas seria cinco vezes mais viagem para
-- a mesma foto.
-- ---------------------------------------------------------------------------
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
        'id', c.id,
        'channel', c.channel,
        'senderId', c.external_sender_id,
        'mode', c.mode,
        'status', c.status,
        'lastWebhookAt', c.last_webhook_at
      )
      from app.channel_connections c
      where c.tenant_id = target_tenant_id and c.channel = 'WHATSAPP'
      order by c.created_at desc
      limit 1
    ), 'null'::jsonb),

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
               order by m2.occurred_at desc
               limit 30
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

comment on function public.site_set_agent_automation(text, text, uuid, boolean, text) is
  'Parada de emergência da resposta automática. Desligar seca a fila do agente, recusa novo enfileiramento com ator AGENT e cancela o que ainda estava PENDING. Nunca bloqueia envio humano.';
