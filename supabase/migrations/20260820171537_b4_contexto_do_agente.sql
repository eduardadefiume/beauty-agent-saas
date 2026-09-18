-- B4 (parte 1): contexto do agente.
--
-- Antes de o agente decidir o que responder, alguem precisa reunir o que ele
-- tem direito de saber. Esta funcao e esse alguem.
--
-- POR QUE NO BANCO, E NAO NA EDGE FUNCTION. Tres razoes:
--   1. E uma consulta, nao uma decisao. Montar o contexto e juntar dados que ja
--      estao aqui; fazer isso do outro lado da rede seria varias idas e voltas.
--   2. Testavel sem LLM. Da para verificar o que o agente enxerga sem gastar um
--      token sequer -- e foi assim que se descobriu que o catalogo do piloto
--      esta vazio.
--   3. Trocar de provedor de LLM nao mexe aqui. O contexto e o mesmo para
--      qualquer modelo.
--
-- O QUE ELE NAO PODE INVENTAR. O agente so pode falar do que estiver neste
-- retorno. Preco nulo e devolvido como nulo de proposito, em vez de omitido:
-- assim o prompt consegue instruir "quando o preco for nulo, diga que vai
-- confirmar com a equipe" em vez de o modelo preencher a lacuna sozinho.
-- Alucinar preco de servico de salao e o tipo de erro que queima a confianca da
-- cliente e do dono no primeiro dia.
--
-- FONTE DO CATALOGO. app.configuration_versions.snapshot -- exatamente o que foi
-- publicado, e nao as tabelas de rascunho. Se a proprietaria nao publicou, o
-- agente nao fala. Isso e proposital.

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

  -- Versao publicada mais recente. Sem publicacao, sem catalogo.
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
      -- Diz ao agente se ele fala como salao, studio de cilios ou manicure.
      -- Muda vocabulario e expectativa da cliente.
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

    -- Catalogo reduzido ao que serve para conversar. Ids internos, requisitos de
    -- recurso e de habilidade ficam de fora: o agente nao precisa deles para
    -- falar com a cliente, e cada campo a mais e contexto pago em token.
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

    -- Historico em ordem cronologica, do mais antigo para o mais novo, que e
    -- como o modelo espera ler uma conversa.
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

    -- A allowlist decide se o agente pode responder sozinho. Vem da ultima
    -- mensagem recebida, que e onde a projecao gravou a decisao.
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

  -- Aviso explicito quando nao ha o que dizer. Sem isso, o agente responderia
  -- com confianca sobre um catalogo inexistente.
  if jsonb_array_length(v_contexto->'catalog') = 0 then
    v_contexto := v_contexto || jsonb_build_object(
      'catalogWarning', 'NENHUM_SERVICO_PUBLICADO'
    );
  end if;

  return v_contexto;
end;
$function$;

-- SECURITY DEFINER lendo dados de cliente de todos os tenants. CREATE FUNCTION
-- concede EXECUTE a PUBLIC por padrao; o fecho vem junto com a criacao.
revoke execute on function app.build_agent_context(uuid, integer) from public;
revoke all on function app.build_agent_context(uuid, integer) from anon, authenticated;
grant execute on function app.build_agent_context(uuid, integer) to service_role;

-- Fachada em public porque o PostgREST so expoe public e graphql_public.
create or replace function public.build_agent_context(
  p_conversation_id uuid,
  p_history_limit integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select app.build_agent_context(p_conversation_id, p_history_limit);
$function$;

revoke all on function public.build_agent_context(uuid, integer) from public, anon, authenticated;
grant execute on function public.build_agent_context(uuid, integer) to service_role;

comment on function app.build_agent_context(uuid, integer) is
  'B4: reune tudo que o agente tem direito de saber para responder uma conversa. Preco nulo e devolvido como nulo de proposito, para o prompt poder instruir o modelo a nao inventar.';
