-- PARAR O AGENTE NUMA CONVERSA, SEM CALAR O SALAO INTEIRO.
--
-- A parada de emergencia que existe hoje (app.agent_automation) e por SALAO:
-- desliga o agente para todas as clientes de uma vez. E o botao certo para
-- "alguma coisa esta muito errada, para tudo agora".
--
-- Mas nao e o botao que o dono vai usar no dia a dia. O caso comum e outro: ele
-- le a conversa com a Maria, ve o agente escorregando num assunto delicado, e
-- quer assumir DAQUELA conversa -- sem deixar as outras trinta clientes sem
-- resposta. Hoje, para fazer isso, ele precisa calar o salao inteiro. Na
-- pratica isso significa que ou ele engole o erro, ou paga caro por corrigi-lo.
--
-- Uma linha aqui quer dizer "nesta conversa quem responde e uma pessoa". O
-- agente continua trabalhando em todas as outras. A fila simplesmente nao
-- enxerga a conversa pausada.
--
-- Mesma forma de app.agent_automation de proposito: quem pausou, quando e por
-- que ficam gravados. Parada sem autor e parada que ninguem sabe desfazer.

create table if not exists app.agent_conversation_pause (
  tenant_id uuid not null references app.tenants(id) on delete cascade,
  conversation_id uuid not null,
  paused boolean not null default true,
  changed_at timestamptz not null default statement_timestamp(),
  changed_by_email text,
  reason text,
  primary key (tenant_id, conversation_id)
);

alter table app.agent_conversation_pause enable row level security;

comment on table app.agent_conversation_pause is
  'Conversas em que o agente esta calado e quem responde e uma pessoa. Nao afeta as outras conversas do salao.';

-- A FILA PASSA A ENXERGAR A PAUSA.
--
-- Unica mudanca em relacao a versao anterior: o `not exists` do final. Todo o
-- resto e identico -- o teto de falhas, a janela de 24h, a espera pela leitura
-- de midia, a retomada quando a dona responde.
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

-- Ligar e desligar a pausa. Upsert: uma linha por conversa, o estado atual e o
-- que vale, e quem mexeu fica gravado.
create or replace function app.set_conversation_pause(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_paused boolean,
  p_email text default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_existe boolean;
begin
  select exists (
    select 1 from app.crm_conversations c
     where c.tenant_id = p_tenant_id and c.id = p_conversation_id
  ) into v_existe;

  if not v_existe then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSATION_NOT_FOUND');
  end if;

  insert into app.agent_conversation_pause (
    tenant_id, conversation_id, paused, changed_at, changed_by_email, reason
  ) values (
    p_tenant_id, p_conversation_id, coalesce(p_paused, true),
    statement_timestamp(), nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_reason, '')), '')
  )
  on conflict (tenant_id, conversation_id) do update
    set paused = excluded.paused,
        changed_at = excluded.changed_at,
        changed_by_email = excluded.changed_by_email,
        reason = excluded.reason;

  return jsonb_build_object('ok', true, 'pausada', coalesce(p_paused, true));
end;
$function$;

revoke all on function app.set_conversation_pause(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function app.set_conversation_pause(uuid, uuid, boolean, text, text) to service_role;

-- As conversas paradas, para a tela mostrar sem o dono precisar procurar.
create or replace function app.paused_conversations(p_tenant_id uuid)
returns table(
  conversation_id uuid,
  contact_label text,
  paused_at timestamptz,
  paused_by text,
  reason text,
  last_message_at timestamptz
)
language sql
stable
security definer
set search_path to ''
as $function$
  select p.conversation_id,
         coalesce(ct.display_name, ch.address_normalized, 'sem nome'),
         p.changed_at, p.changed_by_email, p.reason,
         cv.last_message_at
    from app.agent_conversation_pause p
    join app.crm_conversations cv
      on cv.tenant_id = p.tenant_id and cv.id = p.conversation_id
    left join app.crm_contacts ct
      on ct.tenant_id = cv.tenant_id and ct.id = cv.contact_id
    left join app.crm_contact_channels ch
      on ch.tenant_id = cv.tenant_id and ch.contact_id = cv.contact_id and ch.provider = 'WHATSAPP'
   where p.tenant_id = p_tenant_id and p.paused
   order by p.changed_at desc;
$function$;

revoke all on function app.paused_conversations(uuid) from public, anon, authenticated;
grant execute on function app.paused_conversations(uuid) to service_role;

-- As portas do console. Mesma forma das outras site_*: o email vem do JWT que a
-- edge function ja conferiu, e require_site_tenant recusa quem nao e daquele
-- salao.
create or replace function public.site_set_conversation_pause(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_conversation_id uuid,
  target_paused boolean,
  target_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id);
  return app.set_conversation_pause(
    target_tenant_id, target_conversation_id, target_paused, target_email, target_reason
  );
end;
$function$;

revoke all on function public.site_set_conversation_pause(text, text, uuid, uuid, boolean, text)
  from public, anon, authenticated;
grant execute on function public.site_set_conversation_pause(text, text, uuid, uuid, boolean, text)
  to service_role;

create or replace function public.site_paused_conversations(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_lista jsonb;
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'conversationId', c.conversation_id,
           'quem', c.contact_label,
           'desde', c.paused_at,
           'porQuem', c.paused_by,
           'motivo', c.reason,
           'ultimaMensagem', c.last_message_at
         ) order by c.paused_at desc), '[]'::jsonb)
    into v_lista
    from app.paused_conversations(target_tenant_id) c;

  return jsonb_build_object('ok', true, 'paradas', v_lista);
end;
$function$;

revoke all on function public.site_paused_conversations(text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.site_paused_conversations(text, text, uuid) to service_role;
