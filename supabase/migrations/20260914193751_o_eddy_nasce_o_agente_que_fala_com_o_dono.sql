-- O EDDY: O AGENTE QUE CONVERSA COM O DONO, NAO COM A CLIENTE.
--
-- Dois agentes, duas conversas, dois numeros, e nenhum ponto de contato entre
-- eles:
--
--   agente do salao  -> fala com as CLIENTES, no numero do salao. Um por
--                       cliente do SaaS. Ja existe e esta rodando.
--   Eddy             -> fala com os DONOS, num numero so da EDDigital, o mesmo
--                       para todos os clientes do SaaS. Nasce aqui.
--
-- POR QUE ELE PRECISA DE NUMERO PROPRIO, e a proprietaria quem viu isso
-- primeiro: o dono conversa com o Eddy ANTES de ter WhatsApp conectado --
-- porque e o Eddy que ajuda a conectar. Se o Eddy morasse no numero do salao, a
-- configuracao so poderia comecar depois do passo que ela deveria ajudar a
-- fazer. E, na Coexistencia, o Business App do dono E o numero do salao: ele
-- nao conseguiria mandar mensagem para si mesmo.
--
-- O QUE ELE REUSA, e e quase tudo. O caminho da mensagem e o mesmo do agente
-- das clientes: webhook -> inbox_events -> projecao -> crm_messages -> fila ->
-- decisao -> outbox -> sender. E o braco de escrita dele ja existe desde a
-- etapa 5: `app.onboarding_write`, com a lista branca de quatro destinos, o
-- limite de confianca de 0,75 e o desfazer. O Eddy nao ganha poder novo sobre o
-- banco; ele ganha uma porta de entrada nova.
--
-- O QUE E NOVO AQUI:
--   1. o canal sabe para quem ele serve (`purpose`), e a fila do agente das
--      clientes passa a ignorar canal de dono -- um dono nunca pode ser
--      atendido como se fosse cliente;
--   2. quem e o dono do outro lado, pelo numero dele;
--   3. o diagnostico do negocio: o que ja esta configurado e o que falta, na
--      mesma forma de `client.missing`, que e a maquina que ja funciona;
--   4. o prompt do Eddy, separado do prompt do salao pela coluna `agent`.

-- ---------------------------------------------------------------------------
-- 1. O CANAL SABE PARA QUEM SERVE.
-- ---------------------------------------------------------------------------
alter table app.channel_connections
  add column if not exists purpose text not null default 'CLIENTE';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'channel_connections_purpose_check'
  ) then
    alter table app.channel_connections
      add constraint channel_connections_purpose_check
      check (purpose in ('CLIENTE', 'DONO'));
  end if;
end $$;

comment on column app.channel_connections.purpose is
  'CLIENTE: numero do salao, fala com as clientes. DONO: numero da EDDigital, onde o Eddy fala com os donos.';

-- A fila do agente das clientes passa a ignorar canal de dono. E a trava que
-- impede o pior cruzamento possivel: o agente de atendimento respondendo ao
-- dono com as regras de atender cliente.
create or replace function app.list_conversations_awaiting_agent(
  p_limit integer default 20,
  p_quiet_seconds integer default 25
)
returns table(
  conversation_id uuid,
  tenant_id uuid,
  last_inbound_message_id uuid,
  waiting_seconds integer,
  trigger text
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
grant execute on function app.list_conversations_awaiting_agent(integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 2. QUEM E O DONO DO OUTRO LADO.
--
-- No numero do Eddy escrevem varios donos, de saloes diferentes. O numero de
-- quem escreve e a unica coisa que diz de qual negocio a conversa trata. Sem
-- isso o Eddy configuraria o salao errado -- o pior erro que ele poderia
-- cometer, porque escreve no cadastro de outra pessoa.
-- ---------------------------------------------------------------------------
create table if not exists app.owner_whatsapp (
  phone_digits      text primary key,
  tenant_id         uuid not null references app.tenants(id) on delete cascade,
  display_name      text,
  email_normalized  text,
  status            text not null default 'ACTIVE' check (status in ('ACTIVE', 'REVOKED')),
  created_at        timestamptz not null default statement_timestamp(),
  updated_at        timestamptz not null default statement_timestamp()
);

alter table app.owner_whatsapp enable row level security;

comment on table app.owner_whatsapp is
  'O numero de WhatsApp de cada dono e de qual salao ele e dono. E por aqui que o Eddy sabe em qual cadastro pode escrever.';

create or replace function app.owner_of_whatsapp(p_digits text)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select case when o.phone_digits is null then jsonb_build_object('conhecido', false)
              else jsonb_build_object(
                     'conhecido', true,
                     'tenantId',  o.tenant_id,
                     'negocio',   t.display_name,
                     'nome',      o.display_name,
                     'email',     o.email_normalized
                   )
         end
    from (select 1) um
    left join app.owner_whatsapp o
      on o.phone_digits = regexp_replace(coalesce(p_digits, ''), '[^0-9]', '', 'g')
     and o.status = 'ACTIVE'
    left join app.tenants t on t.id = o.tenant_id;
$function$;

revoke all on function app.owner_of_whatsapp(text) from public, anon, authenticated;
grant execute on function app.owner_of_whatsapp(text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. O DIAGNOSTICO DO NEGOCIO.
--
-- Mesma forma de `client.missing`, de proposito: aquela lista ja provou que
-- funciona -- ela e o que faz o agente perguntar uma coisa por vez, na ordem,
-- sem repetir o que ja sabe. O Eddy herda a maquina inteira, so muda o assunto.
-- ---------------------------------------------------------------------------
create or replace function app.owner_setup_state(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with unidade as (
    select u.* from app.units u
     where u.tenant_id = p_tenant_id
     order by u.created_at limit 1
  ),
  rascunho as (
    select d.* from app.configuration_drafts d
     where d.tenant_id = p_tenant_id
     order by d.revision desc limit 1
  ),
  n as (
    select
      (select name from unidade)                                              as unidade_nome,
      coalesce((select coalesce(address_json, '{}'::jsonb) <> '{}'::jsonb from unidade), false) as tem_endereco,
      coalesce((select active_configuration_version_id is not null from unidade), false)        as publicado,
      (select revision from rascunho)                                         as rascunho_rev,
      (select count(*) from app.operating_hours h
        where h.tenant_id = p_tenant_id
          and h.configuration_draft_id = (select id from rascunho))            as horarios,
      (select count(*) from app.team_members m
        where m.tenant_id = p_tenant_id
          and m.configuration_draft_id = (select id from rascunho)
          and m.status = 'ACTIVE')                                             as profissionais,
      (select count(*) from app.services s
        where s.tenant_id = p_tenant_id
          and s.configuration_draft_id = (select id from rascunho)
          and s.status = 'ACTIVE')                                             as servicos,
      (select count(*) from app.services s
        where s.tenant_id = p_tenant_id
          and s.configuration_draft_id = (select id from rascunho)
          and s.status = 'ACTIVE'
          and s.base_price_minor is null)                                      as servicos_sem_preco,
      (select count(*) from app.agent_policies p
        where p.tenant_id = p_tenant_id and p.status = 'ACTIVE')               as regras,
      (select count(*) from app.status_arts a
        where a.tenant_id = p_tenant_id and a.retired_at is null)              as artes,
      (select count(*) from app.channel_connections c
        where c.tenant_id = p_tenant_id and c.purpose = 'CLIENTE')             as canais
  ),
  falta as (
    select coalesce(jsonb_agg(item order by ordem), '[]'::jsonb) as lista from (
      select 1 as ordem, jsonb_build_object(
        'campo', 'UNIDADE',
        'perguntaSugerida', 'Como se chama o seu salão, e onde ele fica?') as item
        from n where n.unidade_nome is null or not n.tem_endereco
      union all
      select 2, jsonb_build_object(
        'campo', 'HORARIOS',
        'perguntaSugerida', 'Que dias e horários o salão atende?')
        from n where n.horarios = 0
      union all
      select 3, jsonb_build_object(
        'campo', 'PROFISSIONAIS',
        'perguntaSugerida', 'Quem atende no salão? Me fala os nomes.')
        from n where n.profissionais = 0
      union all
      select 4, jsonb_build_object(
        'campo', 'SERVICOS',
        'perguntaSugerida', 'Quais serviços você faz? Pode falar do jeito que você fala com as clientes.')
        from n where n.servicos = 0
      union all
      select 5, jsonb_build_object(
        'campo', 'PRECOS',
        'perguntaSugerida', 'Faltam preços em alguns serviços. Quanto fica cada um?')
        from n where n.servicos_sem_preco > 0
      union all
      select 6, jsonb_build_object(
        'campo', 'REGRAS',
        'perguntaSugerida', 'Tem alguma regra sua que a atendente precisa saber? Do jeito que você diria.')
        from n where n.regras = 0
      union all
      select 7, jsonb_build_object(
        'campo', 'WHATSAPP',
        'perguntaSugerida', 'Falta ligar o WhatsApp do salão. Quer que eu te mande o passo a passo?')
        from n where n.canais = 0
      union all
      select 8, jsonb_build_object(
        'campo', 'PUBLICAR',
        'perguntaSugerida', 'Está tudo cadastrado. Quer que eu publique para a atendente começar a usar?')
        from n where n.canais > 0 and n.servicos > 0 and n.servicos_sem_preco = 0 and not n.publicado
    ) itens
  )
  select jsonb_build_object(
    'negocio',           (select t.display_name from app.tenants t where t.id = p_tenant_id),
    'unidade',           n.unidade_nome,
    'temEndereco',       n.tem_endereco,
    'publicado',         n.publicado,
    'rascunhoRev',       n.rascunho_rev,
    'horarios',          n.horarios,
    'profissionais',     n.profissionais,
    'servicos',          n.servicos,
    'servicosSemPreco',  n.servicos_sem_preco,
    'regras',            n.regras,
    'artes',             n.artes,
    'whatsappConectado', n.canais > 0,
    'falta',             (select lista from falta)
  ) from n;
$function$;

revoke all on function app.owner_setup_state(uuid) from public, anon, authenticated;
grant execute on function app.owner_setup_state(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 4. A FILA DO EDDY e o CONTEXTO DELE.
-- ---------------------------------------------------------------------------
create or replace function app.list_owner_conversations_awaiting_eddy(
  p_limit integer default 10,
  p_quiet_seconds integer default 25
)
returns table(
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
   where cc.purpose = 'DONO'
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
grant execute on function app.list_owner_conversations_awaiting_eddy(integer, integer) to service_role;

create or replace function app.build_owner_context(
  p_conversation_id uuid,
  p_history_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_conversa  app.crm_conversations;
  v_digitos   text;
  v_dono      jsonb;
  v_historico jsonb;
begin
  select * into v_conversa from app.crm_conversations c where c.id = p_conversation_id;
  if v_conversa.id is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSA_NAO_ENCONTRADA');
  end if;

  select ch.address_normalized into v_digitos
    from app.crm_contact_channels ch
   where ch.contact_id = v_conversa.contact_id and ch.provider = 'WHATSAPP'
   limit 1;

  v_dono := app.owner_of_whatsapp(v_digitos);

  select coalesce(jsonb_agg(x order by x->>'at'), '[]'::jsonb) into v_historico
    from (
      select jsonb_build_object(
               'at', m.occurred_at, 'direction', m.direction,
               'text', coalesce(m.body_text, ''),
               'leituraDaMidia', m.media_understanding
             ) as x
        from app.crm_messages m
       where m.conversation_id = p_conversation_id
       order by m.occurred_at desc
       limit greatest(coalesce(p_history_limit, 20), 1)
    ) ult;

  return jsonb_build_object(
    'ok', true,
    'conversationId', p_conversation_id,
    'now', statement_timestamp(),
    'today', to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
    'dono', v_dono,
    'negocio', case when coalesce((v_dono->>'conhecido')::boolean, false)
                    then app.owner_setup_state((v_dono->>'tenantId')::uuid)
                    else null end,
    'history', v_historico
  );
end;
$function$;

revoke all on function app.build_owner_context(uuid, integer) from public, anon, authenticated;
grant execute on function app.build_owner_context(uuid, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 5. O PROMPT DO EDDY MORA NA MESMA TABELA, SEPARADO POR `agent`.
--
-- Mesma tabela porque e a mesma natureza de coisa e merece o mesmo editor, o
-- mesmo versionamento e o mesmo cache. Coluna separada porque o Eddy nao pode
-- herdar uma linha sequer das regras de atender cliente: ele nao vende, nao
-- oferece horario e nao fala com quem esta comprando.
-- ---------------------------------------------------------------------------
alter table app.agent_prompt_blocks
  add column if not exists agent text not null default 'CLIENTE';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'agent_prompt_blocks_agent_check') then
    alter table app.agent_prompt_blocks
      add constraint agent_prompt_blocks_agent_check check (agent in ('CLIENTE', 'DONO'));
  end if;
end $$;

drop function if exists app.agent_prompt();

create or replace function app.agent_prompt(p_agent text default 'CLIENTE')
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  select string_agg(b.body, E'\n\n' order by b.position, b.code)
    from app.agent_prompt_blocks b
   where b.status = 'ACTIVE'
     and b.agent = coalesce(nullif(trim(p_agent), ''), 'CLIENTE');
$function$;

revoke all on function app.agent_prompt(text) from public, anon, authenticated;
grant execute on function app.agent_prompt(text) to service_role;
