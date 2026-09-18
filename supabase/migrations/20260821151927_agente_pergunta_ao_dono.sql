create table if not exists app.agent_owner_questions (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references app.tenants(id) on delete cascade,
  conversation_id       uuid not null,
  triggering_message_id uuid not null,
  question              text not null check (length(trim(question)) between 3 and 500),
  context_summary       text,
  status                text not null default 'PENDING'
                        check (status in ('PENDING', 'ANSWERED', 'DISMISSED')),
  answer                text,
  answered_by_email     text,
  answered_at           timestamptz,
  consumed_at           timestamptz,
  created_at            timestamptz not null default statement_timestamp(),
  foreign key (tenant_id, conversation_id) references app.crm_conversations (tenant_id, id) on delete cascade
);

create unique index if not exists agent_owner_questions_uma_aberta_por_conversa
  on app.agent_owner_questions (tenant_id, conversation_id)
  where status = 'PENDING';

create index if not exists agent_owner_questions_respondidas_idx
  on app.agent_owner_questions (tenant_id, conversation_id)
  where status = 'ANSWERED' and consumed_at is null;

comment on table app.agent_owner_questions is
  'O que o agente nao soube responder. A cliente fica em espera sem ser avisada; a dona responde uma linha na tela e o agente termina o atendimento.';

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