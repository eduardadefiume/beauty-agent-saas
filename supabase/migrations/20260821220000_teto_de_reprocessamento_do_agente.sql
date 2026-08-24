-- Teto no reprocessamento de conversa que dá erro.
--
-- O buraco, encontrado ao ligar o agendador: quando o agente falha numa
-- conversa por motivo NÃO definitivo (rede, banco, timeout), ele não marca
-- decisão nenhuma — de propósito, para tentar de novo. Só que "de novo" não
-- tinha fim: a conversa voltava à fila a cada minuto, para sempre. Enquanto
-- alguém chamava o worker à mão isso era teórico. Com relógio, virou uma
-- torneira aberta: uma falha que aconteça DEPOIS da chamada ao modelo gasta
-- token a cada minuto, sem parar.
--
-- Tentar de novo continua certo — a maioria dessas falhas é passageira. O que
-- faltava era teto e espaçamento. Aqui a tentativa seguinte se afasta
-- (2, 4, 8, 16 minutos) e na quinta falha a conversa é estacionada.
--
-- E estacionar NÃO PODE SER SILENCIOSO. Uma conversa que o agente desistiu de
-- atender é uma cliente esperando resposta que nunca vem. Por isso a conversa
-- estacionada vira item visível para uma pessoa resolver, do mesmo jeito que a
-- pergunta ao dono — não some num log que ninguém lê.

create table if not exists app.agent_conversation_failures (
  tenant_id       uuid not null,
  conversation_id uuid not null,
  failures        integer not null default 0,
  last_error      text,
  last_failed_at  timestamptz not null default statement_timestamp(),
  parked_at       timestamptz,
  primary key (tenant_id, conversation_id)
);

create index if not exists agent_conversation_failures_estacionadas_idx
  on app.agent_conversation_failures (tenant_id, parked_at desc)
  where parked_at is not null;

comment on table app.agent_conversation_failures is
  'Falhas consecutivas do agente por conversa. Espaça a nova tentativa e estaciona a conversa depois do teto, para que erro repetido não vire gasto infinito.';

-- Quanto esperar antes de tentar de novo: 2, 4, 8, 16 minutos, teto de 30.
create or replace function app.agent_retry_backoff(p_failures integer)
returns interval
language sql
immutable
as $$
  select make_interval(mins => least(power(2, greatest(p_failures, 1))::int, 30));
$$;

-- Registra uma falha. `p_definitive` estaciona na hora — é para o caso em que
-- repetir não tem chance de dar certo (recusa do modelo, resposta sem
-- ferramenta), onde tentar de novo só gastaria token pelo mesmo resultado.
create or replace function app.record_agent_failure(
  p_tenant_id       uuid,
  p_conversation_id uuid,
  p_detail          text,
  p_definitive      boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_teto  constant integer := 5;
  v_linha app.agent_conversation_failures;
begin
  insert into app.agent_conversation_failures as f
         (tenant_id, conversation_id, failures, last_error, last_failed_at, parked_at)
  values (p_tenant_id, p_conversation_id, 1, left(coalesce(p_detail, ''), 800),
          statement_timestamp(),
          case when p_definitive then statement_timestamp() end)
  on conflict (tenant_id, conversation_id) do update
    set failures       = f.failures + 1,
        last_error     = left(coalesce(p_detail, ''), 800),
        last_failed_at = statement_timestamp(),
        parked_at      = case
                           when p_definitive then statement_timestamp()
                           when f.failures + 1 >= v_teto then statement_timestamp()
                           else f.parked_at
                         end
  returning * into v_linha;

  -- Primeira falha definitiva já entra estacionada pelo insert; a não
  -- definitiva só estaciona ao alcançar o teto.
  if v_linha.parked_at is null and v_linha.failures >= v_teto then
    update app.agent_conversation_failures
       set parked_at = statement_timestamp()
     where tenant_id = p_tenant_id and conversation_id = p_conversation_id
    returning * into v_linha;
  end if;

  return jsonb_build_object(
    'failures',   v_linha.failures,
    'parked',     v_linha.parked_at is not null,
    'retryAfter', case when v_linha.parked_at is null
                       then v_linha.last_failed_at + app.agent_retry_backoff(v_linha.failures)
                  end
  );
end;
$function$;

-- Sucesso apaga o histórico de falha: uma queda de rede de ontem não pode
-- contar para o teto de hoje.
create or replace function app.clear_agent_failures(p_tenant_id uuid, p_conversation_id uuid)
returns void
language sql
security definer
set search_path to ''
as $function$
  delete from app.agent_conversation_failures
   where tenant_id = p_tenant_id and conversation_id = p_conversation_id;
$function$;

create or replace function public.record_agent_failure(
  p_tenant_id uuid, p_conversation_id uuid, p_detail text, p_definitive boolean default false
)
returns jsonb
language sql security definer set search_path to ''
as $function$ select app.record_agent_failure(p_tenant_id, p_conversation_id, p_detail, p_definitive); $function$;

create or replace function public.clear_agent_failures(p_tenant_id uuid, p_conversation_id uuid)
returns void
language sql security definer set search_path to ''
as $function$ select app.clear_agent_failures(p_tenant_id, p_conversation_id); $function$;

revoke all on function public.record_agent_failure(uuid, uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.clear_agent_failures(uuid, uuid) from public, anon, authenticated;
grant execute on function public.record_agent_failure(uuid, uuid, text, boolean) to service_role;
grant execute on function public.clear_agent_failures(uuid, uuid) to service_role;

-- A fila passa a respeitar o espaçamento e o estacionamento. Este é o ponto
-- onde a torneira fecha: quem controla quem é processado é a fila, não a
-- boa vontade do worker.
create or replace function app.list_conversations_awaiting_agent(
  p_limit integer default 20,
  p_quiet_seconds integer default 25
)
returns table (
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
   where cv.status = 'OPEN'
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
   order by c.occurred_at
   limit p_limit;
$function$;

revoke all on function app.list_conversations_awaiting_agent(integer, integer) from public, anon, authenticated;
grant execute on function app.list_conversations_awaiting_agent(integer, integer) to service_role;

comment on function app.list_conversations_awaiting_agent(integer, integer) is
  'Fila do agente. Além do silêncio mínimo e da janela de 24h, agora exclui conversa em espera de nova tentativa (recuo 2/4/8/16 min) e conversa estacionada depois de 5 falhas.';

-- Lista para uma pessoa resolver: conversa que o agente desistiu de atender.
-- Existe justamente para que estacionar não vire abandono silencioso.
create or replace function public.site_agent_parked_conversations(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_limit           integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_limite integer := least(greatest(coalesce(target_limit, 50), 1), 200);
begin
  -- O cast importa: require_site_tenant recebe app.tenant_role[], e um literal
  -- array['OWNER','OPERATOR'] vira text[], que não casa com a assinatura.
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'conversationId', f.conversation_id,
             'contactName',    ct.display_name,
             'whatsapp',       ch.address_normalized,
             'failures',       f.failures,
             'lastError',      f.last_error,
             'parkedAt',       f.parked_at,
             'lastInboundAt',  cv.last_inbound_at
           ) order by f.parked_at desc)
      from app.agent_conversation_failures f
      join app.crm_conversations cv
        on cv.tenant_id = f.tenant_id and cv.id = f.conversation_id
      join app.crm_contacts ct
        on ct.tenant_id = cv.tenant_id and ct.id = cv.contact_id
      left join app.crm_contact_channels ch
        on ch.tenant_id = cv.tenant_id and ch.contact_id = cv.contact_id and ch.provider = 'WHATSAPP'
     where f.tenant_id = target_tenant_id
       and f.parked_at is not null
     limit v_limite
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.site_agent_parked_conversations(text, text, uuid, integer) to service_role;

-- Tirar do estacionamento é ato humano e deliberado: alguém olhou, entendeu e
-- devolveu a conversa ao agente. Por isso passa pela mesma autorização.
create or replace function public.site_resume_parked_conversation(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_conversation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  -- O cast importa: require_site_tenant recebe app.tenant_role[], e um literal
  -- array['OWNER','OPERATOR'] vira text[], que não casa com a assinatura.
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  delete from app.agent_conversation_failures
   where tenant_id = target_tenant_id and conversation_id = target_conversation_id;

  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_resume_parked_conversation(text, text, uuid, uuid) to service_role;
