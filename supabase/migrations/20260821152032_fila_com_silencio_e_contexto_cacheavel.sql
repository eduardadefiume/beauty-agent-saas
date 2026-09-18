drop function if exists public.list_conversations_awaiting_agent(integer);
drop function if exists app.list_conversations_awaiting_agent(integer);

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
   order by c.occurred_at
   limit p_limit;
$function$;

revoke all on function app.list_conversations_awaiting_agent(integer, integer) from public, anon, authenticated;
grant execute on function app.list_conversations_awaiting_agent(integer, integer) to service_role;

create or replace function public.list_conversations_awaiting_agent(
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
language sql stable security definer set search_path to ''
as $function$ select * from app.list_conversations_awaiting_agent(p_limit, p_quiet_seconds); $function$;

revoke all on function public.list_conversations_awaiting_agent(integer, integer) from public, anon, authenticated;
grant execute on function public.list_conversations_awaiting_agent(integer, integer) to service_role;

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
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'direction', h.direction,
        'text', h.body_text,
        'at', h.occurred_at
      ) order by h.occurred_at)
      from (
        select m.direction, m.body_text, m.occurred_at
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
    'stable', v_estavel,
    'volatile', v_volatil
  );
end;
$function$;

revoke all on function app.build_agent_context(uuid, integer) from public, anon, authenticated;
grant execute on function app.build_agent_context(uuid, integer) to service_role;
revoke all on function public.build_agent_context(uuid, integer) from public, anon, authenticated;
grant execute on function public.build_agent_context(uuid, integer) to service_role;

comment on function app.build_agent_context(uuid, integer) is
  'B4: contexto do agente partido em stable (igual para todo o salao, vai no prompt de sistema e e cacheado) e volatile (muda por conversa). Nada de relogio dentro de stable.';