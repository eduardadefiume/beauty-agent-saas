create table if not exists app.agent_alerts (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references app.tenants(id) on delete cascade,
  kind          text not null,
  detail        text,
  occurrences   integer not null default 1,
  first_seen_at timestamptz not null default statement_timestamp(),
  last_seen_at  timestamptz not null default statement_timestamp(),
  notified_at   timestamptz,
  resolved_at   timestamptz
);

alter table app.agent_alerts enable row level security;

create unique index if not exists agent_alerts_um_aberto_por_tipo_idx
  on app.agent_alerts (tenant_id, kind)
  where resolved_at is null;

create index if not exists agent_alerts_abertos_idx
  on app.agent_alerts (tenant_id, last_seen_at desc)
  where resolved_at is null;

comment on table app.agent_alerts is
  'O que esta impedindo o agente de trabalhar, em linguagem de gente. Uma linha aberta por problema; fecha sozinha quando o agente volta a responder.';

create or replace function app.tipo_do_problema(p_erro text)
returns text
language sql
immutable
as $function$
  select case
    when coalesce(p_erro, '') ~* 'credit balance'                         then 'SEM_CREDITO'
    when coalesce(p_erro, '') ~* 'authentication_error|invalid x-api-key' then 'CHAVE_DA_IA_INVALIDA'
    when coalesce(p_erro, '') ~* 'rate.?limit|\m429\M|overloaded|\m529\M' then 'IA_OCUPADA'
    when coalesce(p_erro, '') ~* 'OAuthException|access token|\(#190'     then 'TOKEN_DO_WHATSAPP'
    else null
  end;
$function$;

create or replace function app.recado_do_problema(p_kind text)
returns text
language sql
immutable
as $function$
  select case p_kind
    when 'SEM_CREDITO'          then 'O agente parou de responder: acabou o crédito da IA. Ele volta sozinho assim que você recarregar.'
    when 'CHAVE_DA_IA_INVALIDA' then 'O agente parou de responder: a chave da IA foi recusada. Precisa ser trocada na configuração.'
    when 'IA_OCUPADA'           then 'A IA está sobrecarregada e o agente está demorando para responder. Costuma passar sozinho em alguns minutos.'
    when 'TOKEN_DO_WHATSAPP'    then 'O WhatsApp recusou o acesso do agente. O token do número precisa ser renovado.'
    when 'AGENTE_FALHANDO'      then 'O agente está falhando seguido em pelo menos uma conversa. Vale olhar as conversas paradas.'
    else 'O agente encontrou um problema repetido.'
  end;
$function$;

create or replace function app.raise_agent_alert(
  p_tenant_id uuid,
  p_kind      text,
  p_detail    text
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
begin
  insert into app.agent_alerts as a (tenant_id, kind, detail)
  values (p_tenant_id, p_kind, left(coalesce(p_detail, ''), 800))
  on conflict (tenant_id, kind) where resolved_at is null
  do update set occurrences  = a.occurrences + 1,
                last_seen_at = statement_timestamp(),
                detail       = left(coalesce(p_detail, ''), 800)
  returning id into v_id;
  return v_id;
end;
$function$;

create or replace function app.aviso_de_espera(p_tenant_id uuid, p_conversation_id uuid, p_desde timestamptz)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_ultima   record;
  v_resposta jsonb;
begin
  if not app.agent_automation_enabled(p_tenant_id) then
    return false;
  end if;

  if exists (
    select 1 from app.agent_conversation_pause p
     where p.tenant_id = p_tenant_id and p.conversation_id = p_conversation_id and p.paused
  ) then
    return false;
  end if;

  select m.direction into v_ultima
    from app.crm_messages m
   where m.tenant_id = p_tenant_id and m.conversation_id = p_conversation_id
     and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
   order by m.occurred_at desc
   limit 1;

  if not found or v_ultima.direction <> 'INBOUND' then
    return false;
  end if;

  v_resposta := app.enqueue_outbound_message(
    p_tenant_id,
    p_conversation_id,
    'Oi! Tive um probleminha aqui pra te responder agora. Já já eu te retorno, tá?',
    'SYSTEM'::app.outbound_actor,
    'espera:' || p_conversation_id::text || ':' || extract(epoch from p_desde)::bigint::text
  );

  return coalesce((v_resposta->>'ok')::boolean, false)
     and not coalesce((v_resposta->>'duplicate')::boolean, false);
end;
$function$;

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
  v_kind  text;
  v_avisou boolean := false;
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

  if v_linha.parked_at is null and v_linha.failures >= v_teto then
    update app.agent_conversation_failures
       set parked_at = statement_timestamp()
     where tenant_id = p_tenant_id and conversation_id = p_conversation_id
    returning * into v_linha;
  end if;

  v_kind := app.tipo_do_problema(p_detail);
  if v_kind is null and (v_linha.failures >= 2 or v_linha.parked_at is not null) then
    v_kind := 'AGENTE_FALHANDO';
  end if;
  if v_kind is not null then
    perform app.raise_agent_alert(p_tenant_id, v_kind, p_detail);
  end if;

  if v_linha.failures = 2 or (v_linha.parked_at is not null and v_linha.failures <= 2) then
    begin
      v_avisou := app.aviso_de_espera(p_tenant_id, p_conversation_id, v_linha.last_failed_at);
    exception when others then
      v_avisou := false;
    end;
  end if;

  return jsonb_build_object(
    'failures',   v_linha.failures,
    'parked',     v_linha.parked_at is not null,
    'alerta',     v_kind,
    'avisouACliente', v_avisou,
    'retryAfter', case when v_linha.parked_at is null
                       then v_linha.last_failed_at + app.agent_retry_backoff(v_linha.failures)
                  end
  );
end;
$function$;

create or replace function app.clear_agent_failures(p_tenant_id uuid, p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
  delete from app.agent_conversation_failures
   where tenant_id = p_tenant_id and conversation_id = p_conversation_id;

  update app.agent_alerts
     set resolved_at = statement_timestamp()
   where tenant_id = p_tenant_id
     and resolved_at is null
     and kind in ('SEM_CREDITO', 'CHAVE_DA_IA_INVALIDA', 'IA_OCUPADA', 'TOKEN_DO_WHATSAPP');

  update app.agent_alerts a
     set resolved_at = statement_timestamp()
   where a.tenant_id = p_tenant_id
     and a.resolved_at is null
     and a.kind = 'AGENTE_FALHANDO'
     and not exists (
       select 1 from app.agent_conversation_failures f
        where f.tenant_id = p_tenant_id and f.failures >= 2
     );
end;
$function$;

create or replace function public.site_agent_alerts(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',        a.id,
             'tipo',      a.kind,
             'recado',    app.recado_do_problema(a.kind),
             'vezes',     a.occurrences,
             'desde',     a.first_seen_at,
             'ultimaVez', a.last_seen_at,
             'detalhe',   a.detail
           ) order by a.last_seen_at desc)
      from app.agent_alerts a
     where a.tenant_id = target_tenant_id
       and a.resolved_at is null
  ), '[]'::jsonb);
end;
$function$;

revoke all on function public.site_agent_alerts(text, text, uuid) from public, anon, authenticated;
grant execute on function public.site_agent_alerts(text, text, uuid) to service_role;

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