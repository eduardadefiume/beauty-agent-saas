-- Três problemas de uma vez, porque são o mesmo problema visto de ângulos
-- diferentes: o agente estava caro, falava como robô e abandonava a cliente.
--
-- ---------------------------------------------------------------------------
-- 1. CUSTO: contexto partido em estável e volátil.
--
-- Medido na primeira chamada real: 5.252 tokens de entrada, 154 de saída. Em
-- Opus 5 isso é US$ 0,030 por mensagem. A 200 mensagens/dia dá mil reais por
-- mês -- inviável para um salão.
--
-- Quase toda essa entrada é catálogo: 26 serviços reenviados inteiros a cada
-- mensagem. O cache de prompt da API cobra 10% pela leitura de um prefixo já
-- visto, mas só funciona se o prefixo for byte a byte idêntico entre chamadas.
-- Hoje não é: catálogo e histórico vão juntos na mesma mensagem, e o histórico
-- muda sempre.
--
-- A correção é estrutural, não um ajuste: `stable` reúne o que é igual para
-- todas as conversas do mesmo salão (identidade, catálogo, horário, equipe) e
-- vai no prompt de sistema, marcado para cache. `volatile` reúne o que muda
-- por conversa e vai depois. Nada de timestamp dentro de `stable` -- um
-- relógio ali dentro invalidaria o cache a cada chamada, silenciosamente.
--
-- ---------------------------------------------------------------------------
-- 2. ABANDONO: o agente não pode mais dizer "vou verificar".
--
-- A Duda foi direta: o agente responde ou fica quieto; ele nunca narra o que
-- vai fazer. Só que "ficar quieto" sem mais nada é abandonar a cliente.
--
-- Daí esta tabela. Quando o agente não sabe, ele não fala nada para a cliente
-- e grava a pergunta para a dona. A cliente fica em espera sem perceber que
-- houve um obstáculo; a dona vê a pergunta na tela e responde uma linha; e a
-- conversa volta para a fila do agente, agora com a resposta em mãos, para ele
-- terminar o atendimento.
--
-- É o que uma recepcionista faz quando não sabe o preço: ela não diz "vou
-- perguntar e te retorno", ela vira e pergunta.
--
-- ---------------------------------------------------------------------------
-- 3. RAJADA: três mensagens seguidas viram uma resposta.
--
-- Cliente escreve "oi", "tudo bem?", "queria saber da progressiva" em vinte
-- segundos. Hoje isso são três chamadas ao modelo e três respostas soltas --
-- caro e desumano, porque ninguém responde linha por linha. A fila passa a
-- exigir alguns segundos de silêncio antes de entregar a conversa ao agente.

-- ---------------------------------------------------------------------------
-- A fila de perguntas ao dono.
-- ---------------------------------------------------------------------------
create table if not exists app.agent_owner_questions (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references app.tenants(id) on delete cascade,
  conversation_id       uuid not null,
  triggering_message_id uuid not null,
  -- O que o agente precisa saber, escrito para uma pessoa ocupada ler em dois
  -- segundos entre uma cliente e outra.
  question              text not null check (length(trim(question)) between 3 and 500),
  -- O que a cliente quer, para a dona responder sem abrir a conversa inteira.
  context_summary       text,
  status                text not null default 'PENDING'
                        check (status in ('PENDING', 'ANSWERED', 'DISMISSED')),
  answer                text,
  answered_by_email     text,
  answered_at           timestamptz,
  -- Marcado quando o agente já usou esta resposta para falar com a cliente.
  -- Sem isso, a conversa voltaria para a fila para sempre depois de respondida.
  consumed_at           timestamptz,
  created_at            timestamptz not null default statement_timestamp(),
  foreign key (tenant_id, conversation_id) references app.crm_conversations (tenant_id, id) on delete cascade
);

-- Uma pergunta aberta por vez, por conversa. Se o agente insistir em perguntar
-- de novo sobre a mesma coisa, a dona não recebe a mesma dúvida duplicada.
create unique index if not exists agent_owner_questions_uma_aberta_por_conversa
  on app.agent_owner_questions (tenant_id, conversation_id)
  where status = 'PENDING';

create index if not exists agent_owner_questions_respondidas_idx
  on app.agent_owner_questions (tenant_id, conversation_id)
  where status = 'ANSWERED' and consumed_at is null;

comment on table app.agent_owner_questions is
  'O que o agente não soube responder. A cliente fica em espera sem ser avisada; a dona responde uma linha na tela e o agente termina o atendimento.';


-- ---------------------------------------------------------------------------
-- Registrar a pergunta.
-- ---------------------------------------------------------------------------
create or replace function app.record_owner_question(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_message_id uuid,
  p_question text,
  p_context_summary text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
begin
  if p_question is null or length(trim(p_question)) < 3 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_QUESTION');
  end if;

  insert into app.agent_owner_questions (
    tenant_id, conversation_id, triggering_message_id, question, context_summary
  )
  values (
    p_tenant_id, p_conversation_id, p_message_id,
    left(trim(p_question), 500), left(p_context_summary, 1000)
  )
  on conflict do nothing
  returning id into v_id;

  if v_id is null then
    -- Já existe pergunta aberta nesta conversa: não duplica.
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'questionId', v_id);
end;
$function$;

revoke all on function app.record_owner_question(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function app.record_owner_question(uuid, uuid, uuid, text, text) to service_role;

create or replace function public.record_owner_question(
  p_tenant_id uuid, p_conversation_id uuid, p_message_id uuid,
  p_question text, p_context_summary text default null
)
returns jsonb language sql security definer set search_path to ''
as $function$
  select app.record_owner_question(p_tenant_id, p_conversation_id, p_message_id, p_question, p_context_summary);
$function$;

revoke all on function public.record_owner_question(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.record_owner_question(uuid, uuid, uuid, text, text) to service_role;


-- Marcar as respostas como usadas, depois que o agente falou com a cliente.
create or replace function app.consume_owner_answers(
  p_tenant_id uuid,
  p_conversation_id uuid
)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_n integer;
begin
  update app.agent_owner_questions
     set consumed_at = statement_timestamp()
   where tenant_id = p_tenant_id
     and conversation_id = p_conversation_id
     and status = 'ANSWERED'
     and consumed_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

revoke all on function app.consume_owner_answers(uuid, uuid) from public, anon, authenticated;
grant execute on function app.consume_owner_answers(uuid, uuid) to service_role;

create or replace function public.consume_owner_answers(p_tenant_id uuid, p_conversation_id uuid)
returns integer language sql security definer set search_path to ''
as $function$ select app.consume_owner_answers(p_tenant_id, p_conversation_id); $function$;

revoke all on function public.consume_owner_answers(uuid, uuid) from public, anon, authenticated;
grant execute on function public.consume_owner_answers(uuid, uuid) to service_role;


-- ---------------------------------------------------------------------------
-- A decisão do agente ganha um quarto valor.
-- ---------------------------------------------------------------------------
create or replace function app.mark_agent_decision(
  p_tenant_id uuid,
  p_message_id uuid,
  p_decision text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_atualizadas integer;
begin
  if p_decision is null or p_decision not in ('REPLY', 'HANDOFF', 'ASK_OWNER', 'ERROR') then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_DECISION');
  end if;

  update app.crm_messages m
     set metadata_minimized = coalesce(m.metadata_minimized, '{}'::jsonb)
       || jsonb_build_object(
            'agentDecision', p_decision,
            'agentDecisionReason', left(coalesce(p_reason, ''), 500),
            'agentDecidedAt', to_char(statement_timestamp() at time zone 'UTC',
                                      'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          )
   where m.tenant_id = p_tenant_id
     and m.id = p_message_id
     and m.direction = 'INBOUND'
     and not (coalesce(m.metadata_minimized, '{}'::jsonb) ? 'agentDecision');

  get diagnostics v_atualizadas = row_count;

  if v_atualizadas = 0 then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false);
end;
$function$;

revoke all on function app.mark_agent_decision(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function app.mark_agent_decision(uuid, uuid, text, text) to service_role;


-- ---------------------------------------------------------------------------
-- A fila: agora com silêncio mínimo e com retomada.
--
-- Duas portas de entrada, e é por isso que o corpo virou um UNION:
--
--   (a) cliente falou e ninguém respondeu ainda;
--   (b) a dona respondeu uma pergunta e o agente precisa voltar para fechar.
--
-- A porta (b) ignora o silêncio mínimo de propósito: a cliente já está
-- esperando há um tempo, não faz sentido esperar mais.
-- ---------------------------------------------------------------------------
-- Assinatura e retorno mudam (ganha `trigger` e o silêncio mínimo), então
-- precisa cair antes: CREATE OR REPLACE não altera tipo de retorno.
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
  -- (a) alguém está esperando resposta
  novas as (
    select u.conversation_id, u.tenant_id, u.message_id, u.occurred_at, 'NOVA_MENSAGEM' as trigger
      from ultima u
     where u.direction = 'INBOUND'
       and u.pode_responder
       and not u.ja_decidido
       -- Silêncio mínimo: rajada de mensagens vira uma resposta só.
       and u.occurred_at < (statement_timestamp() - make_interval(secs => greatest(coalesce(p_quiet_seconds, 25), 0)))
  ),
  -- (b) a dona respondeu; o agente volta para fechar
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


-- ---------------------------------------------------------------------------
-- O contexto, agora partido.
--
-- `stable` NÃO PODE conter relógio, id de conversa, nome de cliente ou
-- qualquer coisa que mude entre duas chamadas do mesmo salão. Cada byte que
-- variar ali derruba o cache -- e derruba em silêncio, sem erro, só com a
-- conta subindo.
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

  -- Igual para toda conversa deste salão. É o prefixo que vai para o cache.
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

    -- O que a dona respondeu e o agente ainda não usou. É isto que permite
    -- fechar a conversa sem nunca ter dito "vou verificar".
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
  'B4: contexto do agente partido em `stable` (igual para todo o salão, vai no prompt de sistema e é cacheado) e `volatile` (muda por conversa). Nada de relógio dentro de `stable`.';


-- ---------------------------------------------------------------------------
-- O que a dona vê e o que ela faz.
--
-- Responder é uma linha de texto. Nada de formulário: a pessoa está entre uma
-- cliente e outra, e uma pergunta que exige três campos para responder não é
-- respondida -- vira fila parada e cliente esperando.
-- ---------------------------------------------------------------------------
create or replace function public.site_answer_owner_question(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_question_id uuid,
  target_answer text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_n integer;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if target_answer is null or length(trim(target_answer)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_ANSWER');
  end if;

  update app.agent_owner_questions
     set status = 'ANSWERED',
         answer = left(trim(target_answer), 2000),
         answered_by_email = target_email,
         answered_at = statement_timestamp()
   where id = target_question_id
     and tenant_id = target_tenant_id
     and status = 'PENDING';

  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'QUESTION_NOT_PENDING');
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_answer_owner_question(text, text, uuid, uuid, text) to service_role;

-- Descartar é para a pergunta que não faz sentido responder (a cliente
-- desistiu, o agente entendeu errado). Some da fila da dona e não volta para o
-- agente.
create or replace function public.site_dismiss_owner_question(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_question_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  update app.agent_owner_questions
     set status = 'DISMISSED', answered_by_email = target_email, answered_at = statement_timestamp()
   where id = target_question_id and tenant_id = target_tenant_id and status = 'PENDING';

  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_dismiss_owner_question(text, text, uuid, uuid) to service_role;
