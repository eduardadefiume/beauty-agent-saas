-- MENSAGEM QUE CHEGA DURANTE A RESPOSTA NÃO SE PERDE.
--
-- 10/10/2026, PRODUÇÃO, William configurando o salão pelo Eddy:
--   10:41:35  William: "E deixar isso explicado já na conversa de agendamento"
--   10:42:04  William: "Para os agendamentos em outros meses ... desmarcações 2 DIAS antes ..."
--   10:42:10  Eddy responde a mensagem das 10:41:35
-- A das 10:42:04 nunca foi respondida e nenhum alerta saiu. A fila do Eddy, a
-- da atendente e o vigia olhavam só a ÚLTIMA mensagem da conversa: como a
-- resposta do Eddy saiu depois, a conversa parecia respondida. O mesmo
-- aconteceu às 10:34:06 ("depois do atendimento também uma mensagem querendo
-- um feedback"). Qualquer mensagem que chegue enquanto o agente está
-- pensando (10 a 40 s) some calada.
--
-- Regra nova, a mesma nas três filas: uma mensagem recebida está pendente se
-- não tem decisão do agente e nenhuma recebida DEPOIS dela tem (a decisão é
-- gravada na última do lote; as anteriores do lote foram lidas juntas). Uma
-- resposta de pessoa pelo painel (actor que não é AGENT/SYSTEM) depois dela
-- também conta como respondida.

create or replace function app.recebidas_pendentes(
  p_desde interval default interval '7 days',
  p_so_as_que_o_agente_pode_responder boolean default false
)
returns table (tenant_id uuid, conversation_id uuid, message_id uuid, occurred_at timestamptz)
language sql
stable
security definer
set search_path to ''
as $function$
  with recebidas as (
    select m.tenant_id, m.conversation_id, m.id, m.occurred_at,
           (m.metadata_minimized ? 'agentDecision') as decidida,
           coalesce((m.metadata_minimized->>'agentMayReply')::boolean, false) as pode_responder
      from app.crm_messages m
     where m.direction = 'INBOUND'
       and m.occurred_at > statement_timestamp() - p_desde
       and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
  ),
  ultima_decidida as (
    select r.tenant_id, r.conversation_id, max(r.occurred_at) as ate
      from recebidas r
     where r.decidida
     group by r.tenant_id, r.conversation_id
  )
  select distinct on (r.tenant_id, r.conversation_id)
         r.tenant_id, r.conversation_id, r.id, r.occurred_at
    from recebidas r
    left join ultima_decidida d
      on d.tenant_id = r.tenant_id and d.conversation_id = r.conversation_id
   where not r.decidida
     and (not p_so_as_que_o_agente_pode_responder or r.pode_responder)
     and (d.ate is null or r.occurred_at > d.ate)
     and not exists (
       select 1 from app.crm_messages h
        where h.tenant_id = r.tenant_id
          and h.conversation_id = r.conversation_id
          and h.direction = 'OUTBOUND'
          and h.occurred_at > r.occurred_at
          and coalesce(h.metadata_minimized->>'actor', 'AGENT') not in ('AGENT', 'SYSTEM')
          and coalesce(h.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED')
   order by r.tenant_id, r.conversation_id, r.occurred_at desc;
$function$;

comment on function app.recebidas_pendentes(interval, boolean) is
  'Por conversa, a última mensagem recebida que nenhum agente decidiu (nem ela nem uma posterior) e que nenhuma pessoa respondeu.';

-- ---------------------------------------------------------------------------
-- 1. FILA DO EDDY
-- ---------------------------------------------------------------------------
create or replace function app.list_owner_conversations_awaiting_eddy(p_limit integer default 10, p_quiet_seconds integer default 25)
returns table (conversation_id uuid, tenant_id uuid, last_inbound_message_id uuid, waiting_seconds integer)
language sql
stable
security definer
set search_path to ''
as $function$
  select u.conversation_id, u.tenant_id, u.message_id,
         extract(epoch from (statement_timestamp() - u.occurred_at))::integer
    from app.recebidas_pendentes(interval '7 days', false) u
    join app.crm_conversations cv on cv.id = u.conversation_id
    join app.channel_connections cc on cc.id = cv.channel_connection_id
   where (cc.purpose = 'DONO' or app.conversa_e_do_dono(u.conversation_id))
     and cv.status = 'OPEN'
     and u.occurred_at < (statement_timestamp() - make_interval(secs => greatest(coalesce(p_quiet_seconds, 25), 0)))
     and not exists (
       select 1 from app.agent_conversation_failures f
        where f.conversation_id = u.conversation_id
          and (f.parked_at is not null
               or statement_timestamp() < f.last_failed_at + app.agent_retry_backoff(f.failures))
     )
     and not exists (
       select 1 from app.crm_messages mm
        where mm.conversation_id = u.conversation_id
          and mm.direction = 'INBOUND'
          and mm.message_type = 'MEDIA'
          and mm.media_understanding is null
          and mm.media_attempts < 3
          and mm.occurred_at > statement_timestamp() - interval '10 minutes'
     )
   order by u.occurred_at
   limit p_limit;
$function$;

-- ---------------------------------------------------------------------------
-- 2. FILA DA ATENDENTE
-- ---------------------------------------------------------------------------
create or replace function app.list_conversations_awaiting_agent(p_limit integer default 20, p_quiet_seconds integer default 25)
returns table (conversation_id uuid, tenant_id uuid, last_inbound_message_id uuid, waiting_seconds integer, trigger text)
language sql
stable
security definer
set search_path to ''
as $function$
  with ultima_recebida as (
    select distinct on (m.tenant_id, m.conversation_id)
           m.tenant_id, m.conversation_id, m.id as message_id, m.occurred_at
      from app.crm_messages m
     where m.direction = 'INBOUND'
       and coalesce((m.metadata_minimized->>'agentMayReply')::boolean, false)
     order by m.tenant_id, m.conversation_id, m.occurred_at desc
  ),
  novas as (
    select u.conversation_id, u.tenant_id, u.message_id, u.occurred_at, 'NOVA_MENSAGEM' as trigger
      from app.recebidas_pendentes(interval '24 hours', true) u
     where u.occurred_at < (statement_timestamp() - make_interval(secs => greatest(coalesce(p_quiet_seconds, 25), 0)))
  ),
  retomadas as (
    select distinct q.conversation_id, q.tenant_id, r.message_id, r.occurred_at, 'RESPOSTA_DO_DONO' as trigger
      from app.agent_owner_questions q
      join ultima_recebida r
        on r.tenant_id = q.tenant_id and r.conversation_id = q.conversation_id
     where q.status = 'ANSWERED' and q.consumed_at is null
  ),
  candidatas as (
    select * from novas
    union
    select * from retomadas r
     where not exists (select 1 from novas n
                        where n.tenant_id = r.tenant_id
                          and n.conversation_id = r.conversation_id)
  )
  select c.conversation_id, c.tenant_id, c.message_id,
         extract(epoch from (statement_timestamp() - c.occurred_at))::integer,
         c.trigger
    from candidatas c
    join app.crm_conversations cv
      on cv.tenant_id = c.tenant_id and cv.id = c.conversation_id
    join app.channel_connections cc
      on cc.id = cv.channel_connection_id
   where cv.status = 'OPEN'
     and cc.purpose = 'CLIENTE'
     and not app.conversa_e_do_dono(c.conversation_id)
     and cv.last_inbound_at > (statement_timestamp() - interval '24 hours')
     and app.agent_automation_enabled(c.tenant_id)
     and not exists (
       select 1
         from app.agent_conversation_failures f
        where f.tenant_id = c.tenant_id
          and f.conversation_id = c.conversation_id
          and (
            f.parked_at is not null
            or statement_timestamp() < f.last_failed_at + app.agent_retry_backoff(f.failures)
          )
     )
     and not exists (
       select 1
         from app.crm_messages mm
        where mm.tenant_id = c.tenant_id
          and mm.conversation_id = c.conversation_id
          and mm.direction = 'INBOUND'
          and mm.message_type = 'MEDIA'
          and mm.media_understanding is null
          and mm.media_attempts < 3
          and mm.occurred_at > statement_timestamp() - interval '10 minutes'
     )
     and not exists (
       select 1
         from app.agent_conversation_pause p
        where p.tenant_id = c.tenant_id
          and p.conversation_id = c.conversation_id
          and p.paused
     )
   order by c.occurred_at
   limit p_limit;
$function$;

-- ---------------------------------------------------------------------------
-- 3. VIGIA
-- ---------------------------------------------------------------------------
-- Dois jeitos de ficar sem resposta: a última mensagem é da cliente/dono
-- (REPLY marcado sem nada sair, 07/10) ou uma recebida no meio ficou sem
-- decisão e sem nada decidido depois dela (10/10).
create or replace function app.mensagens_sem_resposta(p_minutos integer default 15)
returns table (message_id uuid, tenant_id uuid, conversation_id uuid, desde timestamptz, quem text)
language sql
stable
security definer
set search_path to ''
as $function$
  with ultima as (
    select distinct on (m.tenant_id, m.conversation_id)
           m.id, m.tenant_id, m.conversation_id, m.direction, m.occurred_at,
           coalesce(m.metadata_minimized->>'agentDecision', '') as decisao
      from app.crm_messages m
     where m.occurred_at > statement_timestamp() - interval '7 days'
       and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
     order by m.tenant_id, m.conversation_id, m.occurred_at desc
  ),
  esperando as (
    -- Olha o que saiu, não a marca: REPLY sem mensagem depois é silêncio
    -- (07/10: envio recusado pela janela de 24h). HANDOFF já tem alerta próprio.
    select u.id, u.tenant_id, u.conversation_id, u.occurred_at
      from ultima u
     where u.direction = 'INBOUND' and u.decisao <> 'HANDOFF'
    union
    select p.message_id, p.tenant_id, p.conversation_id, p.occurred_at
      from app.recebidas_pendentes(interval '7 days', false) p
  )
  select distinct on (e.tenant_id, e.conversation_id)
         e.id, e.tenant_id, e.conversation_id, e.occurred_at,
         case
           when app.conversa_e_do_dono(e.conversation_id) then 'dono'
           when not app.agent_automation_enabled(e.tenant_id) then 'desligada'
           else 'cliente'
         end
    from esperando e
    join app.crm_conversations c on c.tenant_id = e.tenant_id and c.id = e.conversation_id
    join app.channel_connections ch on ch.id = c.channel_connection_id and ch.tenant_id = c.tenant_id
   where e.occurred_at < statement_timestamp() - make_interval(mins => greatest(coalesce(p_minutos, 15), 1))
     and ch.status not in ('DISCONNECTED', 'SUSPENDED')
     and not app.e_da_operadora(c.external_conversation_ref)
     and not exists (
       select 1 from app.agent_conversation_pause p
        where p.tenant_id = e.tenant_id and p.conversation_id = e.conversation_id and p.paused)
     and not exists (
       select 1 from app.mensagens_sem_resposta_avisadas a where a.message_id = e.id)
   order by e.tenant_id, e.conversation_id, e.occurred_at desc;
$function$;

revoke all on function app.recebidas_pendentes(interval, boolean) from public, anon, authenticated;
revoke all on function app.list_owner_conversations_awaiting_eddy(integer, integer) from public, anon, authenticated;
revoke all on function app.list_conversations_awaiting_agent(integer, integer) from public, anon, authenticated;
revoke all on function app.mensagens_sem_resposta(integer) from public, anon, authenticated;
