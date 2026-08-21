-- O agente ganha identidade para consultar a agenda.
--
-- O PROBLEMA. O motor de disponibilidade já existe e já funciona: a Edge
-- Function `scheduling-api` busca horário livre, cria reserva temporária e
-- confirma agendamento. Só que ela autoriza pelo e-mail assinado no JWT de uma
-- pessoa, e o agente não é uma pessoa -- ele roda como worker.
--
-- DUAS SAÍDAS, E POR QUE ESTA.
--   (a) Espelhar cada schedule_* numa variante "para agente" sem checagem de
--       e-mail. São cinco funções duplicadas, cinco lugares para divergir, e a
--       primeira correção aplicada só em uma metade vira bug silencioso.
--   (b) Dar ao agente uma identidade de serviço, como se ele fosse um
--       funcionário com crachá. As funções existentes continuam sendo as
--       únicas, e quem chama passa a ser identificável no log.
--
-- Escolhida a (b). O papel é OPERATOR, não OWNER: o agente consulta agenda e
-- marca horário, mas não mexe em catálogo, preço nem configuração.
--
-- O QUE IMPEDE ALGUÉM DE SE PASSAR PELO AGENTE. Esta identidade não tem senha
-- nem login -- não existe conta de autenticação com este e-mail. Ela só é usada
-- quando a `scheduling-api` recebe o token de worker do Vault, e a própria
-- função recusa este e-mail vindo de um JWT de pessoa. Os dois cadeados
-- precisam abrir juntos.

insert into app.site_identities (tenant_id, site_project_id, email_normalized, role, status)
select t.id, 'owner-console-v1', 'agente@sistema.interno', 'OPERATOR', 'ACTIVE'
  from app.tenants t
 where not exists (
   select 1 from app.site_identities s
    where s.tenant_id = t.id
      and s.site_project_id = 'owner-console-v1'
      and s.email_normalized = 'agente@sistema.interno'
 );

comment on table app.site_identities is
  'Quem pode agir em nome de qual tenant, por projeto de site. Inclui a identidade de serviço agente@sistema.interno, que não tem login e só vale acompanhada do token de worker.';


-- ---------------------------------------------------------------------------
-- O contexto do agente ganha o que falta para ele consultar a agenda:
-- o id da unidade e o id de cada serviço.
--
-- Os ids entram no bloco `stable` porque não mudam entre conversas -- continuam
-- dentro do prefixo cacheado, sem custo por mensagem.
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
    -- O agente precisa saber que dia é hoje para entender "sábado que vem".
    -- Fica no volátil, nunca no estável: um relógio dentro do bloco cacheado
    -- derrubaria o cache a cada chamada.
    'now', to_char(statement_timestamp() at time zone 'America/Sao_Paulo',
                   'YYYY-MM-DD"T"HH24:MI:SS'),
    'today', to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'Day DD/MM/YYYY'),
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
    'unitId', v_conversa.unit_id,
    'stable', v_estavel,
    'volatile', v_volatil
  );
end;
$function$;

revoke all on function app.build_agent_context(uuid, integer) from public, anon, authenticated;
grant execute on function app.build_agent_context(uuid, integer) to service_role;
revoke all on function public.build_agent_context(uuid, integer) from public, anon, authenticated;
grant execute on function public.build_agent_context(uuid, integer) to service_role;
