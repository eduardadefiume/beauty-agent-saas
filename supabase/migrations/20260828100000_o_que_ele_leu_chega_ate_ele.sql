-- O que o leitor entendeu chega até o agente -- e ele espera por isso.
--
-- A peça anterior ensinou o sistema a ler imagem e ouvir áudio, e guardou o
-- resultado em app.crm_messages.media_understanding. Guardar não é entregar:
-- do jeito que estava, o texto ficava no banco e o agente continuava montando
-- o contexto só com body_text -- que numa mensagem de mídia é a legenda, quase
-- sempre vazia. Ele veria exatamente o que viu hoje: nada.
--
-- Três mudanças, e a terceira é a que evita o dano.
--
-- 1. O HISTÓRICO PASSA A CARREGAR A LEITURA. Cada mensagem do histórico ganha
--    'mediaKind' (image, audio, video, document) e 'mediaContent' com o que
--    foi lido. Fica em campo próprio, e não emendado no texto, porque o agente
--    precisa saber a diferença entre o que a cliente ESCREVEU e o que o sistema
--    LEU de uma foto -- a segunda coisa é interpretação, e interpretação erra.
--
-- 2. MÍDIA QUE FALHOU APARECE COMO FALHA. Quando as três tentativas acabam, a
--    mensagem entra no histórico dizendo que veio uma imagem que não pôde ser
--    lida. É o que permite ao agente pedir "amore, manda de novo?" em vez de
--    responder como se nada tivesse chegado.
--
-- 3. A FILA DO AGENTE ESPERA A LEITURA. Conversa com mídia recebida ainda não
--    interpretada não entra na fila. Sem isso o agente responde no escuro --
--    literalmente o que aconteceu hoje, quando a cliente mandou o card de
--    promoção e ele perguntou à dona se existia promoção. O teto é de dez
--    minutos e três tentativas: passado isso a conversa segue mesmo sem
--    leitura, porque cliente esperando para sempre é pior que agente
--    perguntando.
--
-- POR QUE O LEITOR GANHA JOB PRÓPRIO, e a projeção não ganhou. Na projeção a
-- ordem dentro do minuto era tudo: sem ela a mensagem esperava um minuto à toa,
-- e não havia nada que a protegesse. Aqui existe a guarda do item 3 -- se o
-- leitor ainda não terminou, a conversa simplesmente não está na fila, e o
-- agente pega no tique seguinte. Como a ordem não importa mais, o leitor pode
-- correr no seu próprio compasso; a cada 30 segundos, o mesmo do envio, para
-- que a cliente que manda áudio não fique dois minutos no vácuo.

-- ---------------------------------------------------------------------------
-- 0. O agendador precisa reconhecer o terceiro worker.
-- ---------------------------------------------------------------------------
alter table app.worker_runs      drop constraint if exists worker_runs_worker_check;
alter table app.worker_heartbeat drop constraint if exists worker_heartbeat_worker_check;

alter table app.worker_runs
  add constraint worker_runs_worker_check check (worker in ('AGENTE', 'ENVIO', 'MIDIA'));
alter table app.worker_heartbeat
  add constraint worker_heartbeat_worker_check check (worker in ('AGENTE', 'ENVIO', 'MIDIA'));

-- ---------------------------------------------------------------------------
-- 1 e 2. O contexto do agente passa a incluir o que foi lido da mídia.
-- ---------------------------------------------------------------------------
create or replace function app.build_agent_context(
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
  v_conversa record;
  v_snapshot jsonb;
  v_estavel jsonb;
  v_volatil jsonb;
  v_catalogo jsonb;
  v_janela_aberta boolean;
  v_minutos_restantes integer;
begin
  if p_history_limit is null or p_history_limit < 1 or p_history_limit > 100 then
    raise exception 'p_history_limit deve estar entre 1 e 100, recebido %', p_history_limit;
  end if;

  select c.id, c.tenant_id, c.unit_id, c.contact_id, c.status,
         c.last_inbound_at, c.channel_connection_id,
         ch.address_normalized, ct.display_name,
         t.slug as tenant_slug, t.display_name as tenant_name,
         t.segment_hint
    into v_conversa
    from app.crm_conversations c
    join app.crm_contact_channels ch
      on ch.tenant_id = c.tenant_id and ch.contact_id = c.contact_id
     and ch.provider = 'WHATSAPP'
    join app.crm_contacts ct on ct.tenant_id = c.tenant_id and ct.id = c.contact_id
    join app.tenants t on t.id = c.tenant_id
   where c.id = p_conversation_id
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSATION_NOT_FOUND');
  end if;

  select cv.snapshot into v_snapshot
    from app.configuration_versions cv
   where cv.tenant_id = v_conversa.tenant_id
   order by cv.version_number desc
   limit 1;

  v_catalogo := coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s->>'id',
      'name', s->>'name',
      'description', s->>'description',
      'priceMinor', case when s->>'base_price_minor' is null then null
                         else (s->>'base_price_minor')::bigint end,
      'currency', s->>'currency',
      'durationMinutes', (
        select sum((st->>'duration_minutes')::integer)
          from jsonb_array_elements(coalesce(s->'steps', '[]'::jsonb)) st
      ),
      'requiresStrandTest', coalesce((s->>'requires_strand_test')::boolean, false)
    ) order by s->>'name')
    from jsonb_array_elements(coalesce(v_snapshot->'services', '[]'::jsonb)) s
    where coalesce(s->>'status', '') = 'ACTIVE'
  ), '[]'::jsonb);

  v_estavel := jsonb_build_object(
    'unitId', v_conversa.unit_id,
    'business', jsonb_build_object(
      'name', v_conversa.tenant_name,
      'segment', v_conversa.segment_hint
    ),
    'catalog', v_catalogo,
    'operatingHours', coalesce(v_snapshot->'operatingHours', '[]'::jsonb),
    'team', coalesce((
      select jsonb_agg(m->>'name' order by m->>'name')
      from jsonb_array_elements(coalesce(v_snapshot->'teamMembers', '[]'::jsonb)) m
      where coalesce(m->>'status', '') = 'ACTIVE'
    ), '[]'::jsonb)
  );

  if jsonb_array_length(v_catalogo) = 0 then
    v_estavel := v_estavel || jsonb_build_object('catalogWarning', 'NENHUM_SERVICO_PUBLICADO');
  end if;

  v_janela_aberta := v_conversa.last_inbound_at is not null
    and v_conversa.last_inbound_at > (statement_timestamp() - interval '24 hours');

  v_minutos_restantes := case
    when v_conversa.last_inbound_at is null then 0
    else greatest(0, extract(epoch from (
      v_conversa.last_inbound_at + interval '24 hours' - statement_timestamp()
    ))::integer / 60)
  end;

  v_volatil := jsonb_build_object(
    'contact', jsonb_build_object(
      'displayName', v_conversa.display_name,
      'whatsapp', v_conversa.address_normalized
    ),
    'serviceWindow', jsonb_build_object(
      'open', v_janela_aberta,
      'minutesRemaining', v_minutos_restantes
    ),
    'now', to_char(statement_timestamp() at time zone 'America/Sao_Paulo',
                   'YYYY-MM-DD"T"HH24:MI:SS'),
    'today', trim(to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'Day')) || ' ' ||
             to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY'),
    'history', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'direction', h.direction,
          'text', h.body_text,
          'at', h.occurred_at
        )
        -- O que foi LIDO da mídia entra em campo separado do que foi ESCRITO.
        -- Emendar os dois no mesmo 'text' faria o agente tratar a leitura de
        -- uma foto como se fosse frase digitada pela cliente.
        || case
             when h.media_understanding is not null then
               jsonb_build_object(
                 'mediaKind', coalesce(h.media_kind, 'media'),
                 'mediaContent', h.media_understanding
               )
             when h.message_type = 'MEDIA' then
               jsonb_build_object(
                 'mediaKind', coalesce(h.media_kind, 'media'),
                 'mediaContent', null,
                 'mediaUnreadable', true
               )
             else '{}'::jsonb
           end
        order by h.occurred_at)
      from (
        select m.direction, m.body_text, m.occurred_at, m.message_type,
               m.media_understanding,
               m.metadata_minimized->>'eventType' as media_kind
          from app.crm_messages m
         where m.tenant_id = v_conversa.tenant_id
           and m.conversation_id = v_conversa.id
           and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
         order by m.occurred_at desc
         limit p_history_limit
      ) h
    ), '[]'::jsonb),
    'ownerAnswers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'question', q.question,
        'answer', q.answer,
        'answeredAt', q.answered_at
      ) order by q.answered_at)
      from app.agent_owner_questions q
     where q.tenant_id = v_conversa.tenant_id
       and q.conversation_id = v_conversa.id
       and q.status = 'ANSWERED'
       and q.consumed_at is null
    ), '[]'::jsonb),
    'pendingOwnerQuestion', exists (
      select 1 from app.agent_owner_questions q
       where q.tenant_id = v_conversa.tenant_id
         and q.conversation_id = v_conversa.id
         and q.status = 'PENDING'
    ),
    'agentMayReply', coalesce((
      select (m.metadata_minimized->>'agentMayReply')::boolean
        from app.crm_messages m
       where m.tenant_id = v_conversa.tenant_id
         and m.conversation_id = v_conversa.id
         and m.direction = 'INBOUND'
       order by m.occurred_at desc
       limit 1
    ), false)
  );

  return jsonb_build_object(
    'ok', true,
    'conversationId', v_conversa.id,
    'tenantId', v_conversa.tenant_id,
    'unitId', v_conversa.unit_id,
    'stable', v_estavel,
    'volatile', v_volatil
  );
end;
$function$;

comment on function app.build_agent_context(uuid, integer) is
  'Contexto do agente em dois blocos (estavel cacheavel e volatil). O historico carrega mediaKind/mediaContent com o que foi lido de imagem e audio, e marca mediaUnreadable quando a leitura falhou.';

-- ---------------------------------------------------------------------------
-- 3. A guarda: conversa com mídia não lida não entra na fila do agente.
-- ---------------------------------------------------------------------------
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
     -- Espera a leitura da mídia. Vale para QUALQUER mídia recebida nos últimos
     -- dez minutos, não só a última mensagem: é comum a cliente mandar a foto e
     -- escrever logo depois, e responder ao texto ignorando a foto é o mesmo
     -- erro de hoje com outra roupa.
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
   order by c.occurred_at
   limit p_limit;
$function$;

revoke all on function app.list_conversations_awaiting_agent(integer, integer) from public, anon, authenticated;
grant execute on function app.list_conversations_awaiting_agent(integer, integer) to service_role;

comment on function app.list_conversations_awaiting_agent(integer, integer) is
  'Fila do agente. Alem do silencio minimo, da janela de 24h e do recuo por falha, exclui conversa com midia recebida ainda nao interpretada (teto de 3 tentativas ou 10 minutos).';

-- ---------------------------------------------------------------------------
-- O relógio do leitor.
-- ---------------------------------------------------------------------------
select cron.unschedule('midia-whatsapp')
 where exists (select 1 from cron.job where jobname = 'midia-whatsapp');

select cron.schedule('midia-whatsapp', '30 seconds', $cron$
  select app.tick_worker('MIDIA', 'whatsapp-media-reader', '{"limit": 5}'::jsonb, 120000);
$cron$);
