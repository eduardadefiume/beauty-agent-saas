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
  v_contexto jsonb;
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

  v_janela_aberta := v_conversa.last_inbound_at is not null
    and v_conversa.last_inbound_at > (statement_timestamp() - interval '24 hours');

  v_minutos_restantes := case
    when v_conversa.last_inbound_at is null then 0
    else greatest(0, extract(epoch from (
      v_conversa.last_inbound_at + interval '24 hours' - statement_timestamp()
    ))::integer / 60)
  end;

  v_contexto := jsonb_build_object(
    'ok', true,
    'conversationId', v_conversa.id,
    'tenant', jsonb_build_object(
      'id', v_conversa.tenant_id,
      'slug', v_conversa.tenant_slug,
      'name', v_conversa.tenant_name,
      'segment', v_conversa.segment_hint
    ),
    'contact', jsonb_build_object(
      'displayName', v_conversa.display_name,
      'whatsapp', v_conversa.address_normalized
    ),
    'serviceWindow', jsonb_build_object(
      'open', v_janela_aberta,
      'lastInboundAt', v_conversa.last_inbound_at,
      'minutesRemaining', v_minutos_restantes
    ),
    'catalog', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', s->>'name',
        'description', s->>'description',
        'bookable', (s->>'bookable')::boolean,
        'priceMinor', case when s->>'base_price_minor' is null then null
                           else (s->>'base_price_minor')::bigint end,
        'currency', s->>'currency',
        'durationMinutes', (
          select sum((st->>'duration_minutes')::integer)
            from jsonb_array_elements(coalesce(s->'steps', '[]'::jsonb)) st
        ),
        'requiresStrandTest', coalesce((s->>'requires_strand_test')::boolean, false),
        'strandTestLeadDays', case when s->>'strand_test_lead_days' is null then null
                                   else (s->>'strand_test_lead_days')::integer end
      ))
      from jsonb_array_elements(coalesce(v_snapshot->'services', '[]'::jsonb)) s
      where coalesce(s->>'status', '') = 'ACTIVE'
    ), '[]'::jsonb),
    'operatingHours', coalesce(v_snapshot->'operatingHours', '[]'::jsonb),
    'team', coalesce((
      select jsonb_agg(m->>'name')
      from jsonb_array_elements(coalesce(v_snapshot->'teamMembers', '[]'::jsonb)) m
      where coalesce(m->>'status', '') = 'ACTIVE'
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'direction', h.direction,
        'text', h.body_text,
        'type', h.message_type,
        'at', h.occurred_at
      ) order by h.occurred_at)
      from (
        select m.direction, m.body_text, m.message_type, m.occurred_at
          from app.crm_messages m
         where m.tenant_id = v_conversa.tenant_id
           and m.conversation_id = v_conversa.id
         order by m.occurred_at desc
         limit p_history_limit
      ) h
    ), '[]'::jsonb),
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

  if jsonb_array_length(v_contexto->'catalog') = 0 then
    v_contexto := v_contexto || jsonb_build_object('catalogWarning', 'NENHUM_SERVICO_PUBLICADO');
  end if;

  return v_contexto;
end;
$function$;

revoke execute on function app.build_agent_context(uuid, integer) from public;
revoke all on function app.build_agent_context(uuid, integer) from anon, authenticated;
grant execute on function app.build_agent_context(uuid, integer) to service_role;