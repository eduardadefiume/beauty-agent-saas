-- O EDDY ATENDE PELO NUMERO DO SALAO QUANDO QUEM ESCREVE E O DONO.
--
-- O plano era um segundo numero para o Eddy: o de teste da Meta. Ele esbarrou
-- em tres portas que so abrem no navegador da dona -- gerar o token da WABA de
-- teste, cadastrar destinatario na lista "Para", confirmar o codigo -- e em uma
-- que nem abre: o token do usuario do sistema nao alcanca a WABA de teste
-- (Graph code 100, subcode 33).
--
-- Mas o segundo numero nunca foi o requisito. O requisito e saber COM QUEM se
-- esta falando. E isso o WhatsApp ja diz em toda mensagem: o numero de quem
-- escreveu.
--
-- Entao a fila deixa de perguntar so "por qual numero entrou" e passa a
-- perguntar tambem "quem escreveu":
--
--   escreveu de um numero de dono cadastrado  ->  Eddy
--   qualquer outro numero                     ->  a atendente das clientes
--
-- Canal com purpose='DONO' continua indo inteiro para o Eddy, como antes: quem
-- tiver um numero so para o dono nao muda nada.
--
-- E ISSO NAO E GAMBIARRA DE TESTE, e o caminho do produto. Um chip a mais por
-- salao e custo e atrito no onboarding; a maioria vai querer falar com o Eddy
-- do mesmo numero que ja tem. Quem quiser separar, separa.
--
-- O QUE PROTEGE: as duas filas leem a MESMA regra, com sinais opostos. Uma
-- conversa nunca cai nas duas, e nunca fica sem nenhuma.

-- Quem e dono, pelo numero de quem escreveu na conversa.
create or replace function app.conversa_e_do_dono(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
      from app.crm_conversations cv
      join app.owner_whatsapp o
        on o.tenant_id = cv.tenant_id
       and o.status = 'ACTIVE'
       and o.phone_digits = regexp_replace(coalesce(cv.external_conversation_ref, ''), '[^0-9]', '', 'g')
     where cv.id = p_conversation_id
  );
$function$;

revoke all on function app.conversa_e_do_dono(uuid) from public, anon, authenticated;

-- A fila das clientes nunca responde ao dono.
create or replace function app.list_conversations_awaiting_agent(
  p_limit integer default 20,
  p_quiet_seconds integer default 25
)
returns table(
  conversation_id uuid, tenant_id uuid, last_inbound_message_id uuid,
  waiting_seconds integer, trigger text
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
  ),
  ultima_recebida as (
    select distinct on (m.tenant_id, m.conversation_id)
           m.tenant_id, m.conversation_id, m.id as message_id, m.occurred_at
      from app.crm_messages m
     where m.direction = 'INBOUND'
       and coalesce((m.metadata_minimized->>'agentMayReply')::boolean, false)
     order by m.tenant_id, m.conversation_id, m.occurred_at desc
  ),
  novas as (
    select u.conversation_id, u.tenant_id, u.message_id, u.occurred_at, 'NOVA_MENSAGEM' as trigger
      from ultima u
     where u.direction = 'INBOUND'
       and u.pode_responder
       and not u.ja_decidido
       and u.occurred_at < (statement_timestamp() - make_interval(secs => greatest(coalesce(p_quiet_seconds, 25), 0)))
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
    select * from retomadas
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
     -- Quem escreve de um numero de dono cadastrado fala com o Eddy, mesmo
     -- quando entra pelo numero das clientes.
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

revoke all on function app.list_conversations_awaiting_agent(integer, integer) from public, anon, authenticated;

-- E a fila do Eddy pega o dono onde ele estiver: no canal dele, ou escrevendo
-- para o proprio salao.
create or replace function app.list_owner_conversations_awaiting_eddy(
  p_limit integer default 10,
  p_quiet_seconds integer default 25
)
returns table(
  conversation_id uuid, tenant_id uuid, last_inbound_message_id uuid, waiting_seconds integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  with ultima as (
    select distinct on (m.conversation_id)
           m.conversation_id, m.tenant_id, m.id as message_id, m.direction, m.occurred_at,
           (m.metadata_minimized ? 'agentDecision') as ja_decidido
      from app.crm_messages m
     where coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
     order by m.conversation_id, m.occurred_at desc
  )
  select u.conversation_id, u.tenant_id, u.message_id,
         extract(epoch from (statement_timestamp() - u.occurred_at))::integer
    from ultima u
    join app.crm_conversations cv on cv.id = u.conversation_id
    join app.channel_connections cc on cc.id = cv.channel_connection_id
   where (cc.purpose = 'DONO' or app.conversa_e_do_dono(u.conversation_id))
     and cv.status = 'OPEN'
     and u.direction = 'INBOUND'
     and not u.ja_decidido
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

revoke all on function app.list_owner_conversations_awaiting_eddy(integer, integer) from public, anon, authenticated;
