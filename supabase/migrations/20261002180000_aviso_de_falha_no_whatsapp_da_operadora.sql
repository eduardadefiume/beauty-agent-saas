-- O AVISO DE FALHA CHEGA NO WHATSAPP DA OPERADORA.
--
-- 02/10/2026, vespera do teste do William. `agent_alerts` existe desde 17/09 e
-- registra direitinho o que trava o agente (crédito, chave, IA ocupada, falha
-- repetida, pedido fora do alcance) -- mas NINGUEM mandava. No DEV havia 5
-- alertas abertos e a Duda nao soube de nenhum. E o credito acabou hoje sem
-- aviso.
--
-- E havia um buraco pior: crédito acabado é falha de infraestrutura, igual
-- para todas as conversas, mas contava como falha DA CONVERSA. No 5º tropeço
-- (~30 min) a conversa era estacionada e nunca mais voltava, nem depois da
-- recarga. A mensagem do William no DEV ("o 1") ficou assim.
--
-- O que muda:
--   1. app.operator_contacts: quem recebe os avisos (a Duda).
--   2. A conversa da operadora no numero de um salao nasce pausada: a
--      atendente nunca responde a ela (ela le avisos, nao e cliente). Exceto
--      no salao em que ela e dona -- ali quem responde e o Eddy.
--   3. Falha de infraestrutura nao estaciona conversa: tenta de 8 em 8 min, e
--      a primeira resposta boa (de qualquer salao) libera todas na hora.
--   4. app.avisar_operadora(), de minuto em minuto: manda o alerta novo e o
--      "voltou" quando o problema de infraestrutura se resolve. Janela de 24h
--      fechada -> modelo ALERTA_DA_OPERACAO; sem ele aprovado -> AVISO_AO_DONO.
--   5. public.alertar_operadora(): as travas do código (resposta segurada,
--      passou para pessoa) viram alerta. Esse tipo é avisado uma vez e fecha;
--      o próximo abre outro.

-- ---------------------------------------------------------------------------
-- 1. QUEM RECEBE
-- ---------------------------------------------------------------------------
create table if not exists app.operator_contacts (
  phone_digits text primary key check (phone_digits ~ '^[0-9]{10,15}$'),
  name         text not null,
  active       boolean not null default true,
  created_at   timestamptz not null default statement_timestamp()
);

alter table app.operator_contacts enable row level security;

comment on table app.operator_contacts is
  'Quem opera o produto (nao e dono de salao): recebe no WhatsApp os alertas de falha do agente.';

insert into app.operator_contacts (phone_digits, name)
values ('5516994215487', 'Eduarda')
on conflict (phone_digits) do nothing;

-- DDD + 8 ultimos digitos: o mesmo celular chega da Meta com e sem o 9.
-- '5516994215487' e '551694215487' viram os dois '1694215487'.
create or replace function app.chave_do_telefone(p_ref text)
returns text
language sql
immutable
as $function$
  select case
    when length(d) < 10 then null
    else left(d, 2) || right(d, 8)
  end
  from (
    select case
             when length(x) in (12, 13) and x like '55%' then substr(x, 3)
             else x
           end as d
      from (select regexp_replace(coalesce(p_ref, ''), '[^0-9]', '', 'g') as x) a
  ) b;
$function$;

create or replace function app.e_da_operadora(p_ref text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select app.chave_do_telefone(p_ref) is not null
     and exists (
       select 1 from app.operator_contacts o
        where o.active
          and app.chave_do_telefone(o.phone_digits) = app.chave_do_telefone(p_ref)
     );
$function$;

-- ---------------------------------------------------------------------------
-- 2. A ATENDENTE NAO RESPONDE A OPERADORA
-- ---------------------------------------------------------------------------
create or replace function app.operadora_dona_do_salao(p_tenant_id uuid, p_ref text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1 from app.owner_whatsapp o
     where o.tenant_id = p_tenant_id and o.status = 'ACTIVE'
       and app.chave_do_telefone(o.phone_digits) = app.chave_do_telefone(p_ref)
  );
$function$;

create or replace function app.pausar_conversa_da_operadora()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if app.e_da_operadora(new.external_conversation_ref)
     and not app.operadora_dona_do_salao(new.tenant_id, new.external_conversation_ref) then
    insert into app.agent_conversation_pause as p
           (tenant_id, conversation_id, paused, changed_by_email, reason)
    values (new.tenant_id, new.id, true, 'sistema',
            'Número da operadora: recebe os alertas do sistema; a atendente não responde.')
    on conflict (tenant_id, conversation_id) do update
      set paused = true, changed_at = statement_timestamp(),
          changed_by_email = 'sistema', reason = excluded.reason;
  end if;
  return null;
end;
$function$;

drop trigger if exists conversa_da_operadora_nasce_pausada on app.crm_conversations;
create trigger conversa_da_operadora_nasce_pausada
  after insert on app.crm_conversations
  for each row execute function app.pausar_conversa_da_operadora();

-- As que ja existem.
insert into app.agent_conversation_pause as p
       (tenant_id, conversation_id, paused, changed_by_email, reason)
select c.tenant_id, c.id, true, 'sistema',
       'Número da operadora: recebe os alertas do sistema; a atendente não responde.'
  from app.crm_conversations c
 where app.e_da_operadora(c.external_conversation_ref)
   and not app.operadora_dona_do_salao(c.tenant_id, c.external_conversation_ref)
on conflict (tenant_id, conversation_id) do update
  set paused = true, changed_at = statement_timestamp(),
      changed_by_email = 'sistema', reason = excluded.reason;

-- ---------------------------------------------------------------------------
-- 3. FALHA DE INFRAESTRUTURA NAO ESTACIONA CONVERSA
-- ---------------------------------------------------------------------------
create or replace function app.problema_de_infra(p_kind text)
returns boolean
language sql
immutable
as $function$
  select coalesce(p_kind in ('SEM_CREDITO', 'CHAVE_DA_IA_INVALIDA', 'IA_OCUPADA', 'TOKEN_DO_WHATSAPP'), false);
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
  v_teto   constant integer := 5;
  -- Infra: no maximo 3 tropecos contados (8 min entre tentativas), nunca
  -- estaciona. O aviso de espera a cliente sai no 2º, uma vez so.
  v_teto_infra constant integer := 3;
  v_linha  app.agent_conversation_failures;
  v_kind   text := app.tipo_do_problema(p_detail);
  v_infra  boolean := app.problema_de_infra(app.tipo_do_problema(p_detail));
  v_avisou boolean := false;
begin
  insert into app.agent_conversation_failures as f
         (tenant_id, conversation_id, failures, last_error, last_failed_at, parked_at)
  values (p_tenant_id, p_conversation_id, 1, left(coalesce(p_detail, ''), 800),
          statement_timestamp(),
          case when p_definitive and not v_infra then statement_timestamp() end)
  on conflict (tenant_id, conversation_id) do update
    set failures       = case when v_infra then least(f.failures + 1, v_teto_infra)
                              else f.failures + 1 end,
        last_error     = left(coalesce(p_detail, ''), 800),
        last_failed_at = statement_timestamp(),
        parked_at      = case
                           when v_infra then f.parked_at
                           when p_definitive then statement_timestamp()
                           when f.failures + 1 >= v_teto then statement_timestamp()
                           else f.parked_at
                         end
  returning * into v_linha;

  if not v_infra and v_linha.parked_at is null and v_linha.failures >= v_teto then
    update app.agent_conversation_failures
       set parked_at = statement_timestamp()
     where tenant_id = p_tenant_id and conversation_id = p_conversation_id
    returning * into v_linha;
  end if;

  if v_kind is null and (v_linha.failures >= 2 or v_linha.parked_at is not null) then
    v_kind := 'AGENTE_FALHANDO';
  end if;
  if v_kind is not null then
    perform app.raise_agent_alert(p_tenant_id, v_kind, p_detail);
  end if;

  if v_linha.failures = 2 and v_linha.last_failed_at is not null
     and not exists (
       select 1 from app.outbox_messages o
        where o.tenant_id = p_tenant_id
          and o.idempotency_key like 'espera:' || p_conversation_id::text || ':%'
          and o.created_at > statement_timestamp() - interval '6 hours')
     or (v_linha.parked_at is not null and v_linha.failures <= 2) then
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

  -- A IA respondeu: crédito, chave e capacidade sao da conta inteira, nao do
  -- salao. Todas as conversas que esperavam por isso voltam para a fila agora.
  delete from app.agent_conversation_failures f
   where app.tipo_do_problema(f.last_error) in ('SEM_CREDITO', 'CHAVE_DA_IA_INVALIDA', 'IA_OCUPADA');

  update app.agent_alerts
     set resolved_at = statement_timestamp()
   where resolved_at is null
     and kind in ('SEM_CREDITO', 'CHAVE_DA_IA_INVALIDA', 'IA_OCUPADA');

  update app.agent_alerts
     set resolved_at = statement_timestamp()
   where tenant_id = p_tenant_id
     and resolved_at is null
     and kind = 'TOKEN_DO_WHATSAPP';

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

-- Quem ja ficou estacionado por falta de credito volta para a fila.
delete from app.agent_conversation_failures f
 where app.problema_de_infra(app.tipo_do_problema(f.last_error));

-- ---------------------------------------------------------------------------
-- 4. O AVISO SAI
-- ---------------------------------------------------------------------------
alter table app.agent_alerts
  add column if not exists aviso_falhou     text,
  add column if not exists volta_avisada_em timestamptz;

create or replace function app.recado_do_problema(p_kind text)
returns text language sql immutable
as $fn$
  select case p_kind
    when 'SEM_CREDITO'            then 'O agente parou de responder: acabou o crédito da IA. Ele volta sozinho assim que você recarregar.'
    when 'CHAVE_DA_IA_INVALIDA'   then 'O agente parou de responder: a chave da IA foi recusada. Precisa ser trocada na configuração.'
    when 'IA_OCUPADA'             then 'A IA está sobrecarregada e o agente está demorando para responder. Costuma passar sozinho em alguns minutos.'
    when 'TOKEN_DO_WHATSAPP'      then 'O WhatsApp recusou o acesso do agente. O token do número precisa ser renovado.'
    when 'AGENTE_FALHANDO'        then 'O agente está falhando seguido em pelo menos uma conversa. Vale olhar as conversas paradas.'
    when 'PEDIDO_FORA_DO_ALCANCE' then 'O Eddy passou um pedido do dono para uma pessoa (algo que ele não soube ou não pôde fazer).'
    when 'RESPOSTA_BLOQUEADA'     then 'A atendente escreveu algo sem base (horário ou preço) e a trava segurou. A cliente não recebeu o erro, mas a conversa precisa de alguém.'
    when 'PASSOU_PARA_PESSOA'     then 'A atendente passou uma conversa para uma pessoa. Alguém precisa responder a cliente.'
    else 'O agente encontrou um problema.'
  end;
$fn$;

create or replace function app.volta_do_problema(p_kind text)
returns text language sql immutable
as $fn$
  select case p_kind
    when 'SEM_CREDITO'          then 'O crédito da IA voltou e o agente já está respondendo.'
    when 'CHAVE_DA_IA_INVALIDA' then 'A chave da IA voltou a funcionar e o agente já está respondendo.'
    when 'IA_OCUPADA'           then 'A IA normalizou e o agente voltou a responder no tempo normal.'
    when 'TOKEN_DO_WHATSAPP'    then 'O WhatsApp voltou a aceitar o agente.'
    when 'AGENTE_FALHANDO'      then 'As conversas que estavam falhando voltaram a ser respondidas.'
    else 'Resolvido.'
  end;
$fn$;

-- Avisado uma vez e fechado: cada ocorrencia nova abre outro alerta.
create or replace function app.alerta_de_uma_vez(p_kind text)
returns boolean language sql immutable
as $fn$
  select coalesce(p_kind in ('PEDIDO_FORA_DO_ALCANCE', 'RESPOSTA_BLOQUEADA', 'PASSOU_PARA_PESSOA'), false);
$fn$;

create or replace function app.avisar_operadora()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_a        record;
  v_op       record;
  v_conv     record;
  v_salao    text;
  v_codigo   text;
  v_volta    boolean;
  v_texto    text;
  v_curto    text;
  v_r        jsonb;
  v_ok       boolean;
  v_motivo   text;
  v_enviados integer := 0;
  v_falhas   integer := 0;
begin
  for v_a in
    select a.*
      from app.agent_alerts a
     where (a.notified_at is null and a.resolved_at is null
            -- IA ocupada passa sozinha quase sempre: so avisa se insistir.
            and (a.kind <> 'IA_OCUPADA' or a.occurrences >= 3
                 or a.first_seen_at < statement_timestamp() - interval '10 minutes'))
        or (a.notified_at is not null and a.resolved_at is not null
            and a.volta_avisada_em is null and not app.alerta_de_uma_vez(a.kind))
     order by a.first_seen_at
     limit 20
     for update skip locked
  loop
    v_volta  := v_a.resolved_at is not null;
    v_salao  := coalesce((select t.display_name from app.tenants t where t.id = v_a.tenant_id), 'salão');
    v_codigo := upper(left(replace(v_a.id::text, '-', ''), 6));

    if v_volta then
      v_texto := '✅ Resolvido — ' || v_salao || E'\n\n' || app.volta_do_problema(v_a.kind)
              || E'\n\n(código ' || v_codigo || ')';
      v_curto := app.volta_do_problema(v_a.kind);
    else
      v_curto := app.recado_do_problema(v_a.kind)
              || case when app.problema_de_infra(v_a.kind) then ''
                      else ' Detalhe: ' || left(regexp_replace(coalesce(v_a.detail, ''), '\s+', ' ', 'g'), 350) end
              || case when v_a.occurrences > 1 then ' (' || v_a.occurrences || ' vezes)' else '' end;
      v_texto := '⚠️ Alerta do sistema — ' || v_salao || E'\n\n' || app.recado_do_problema(v_a.kind)
              || case when app.problema_de_infra(v_a.kind) then ''
                      else E'\n\nDetalhe: ' || left(coalesce(v_a.detail, ''), 500) end
              || case when v_a.occurrences > 1 then E'\n\nAconteceu ' || v_a.occurrences || ' vezes.' else '' end
              || E'\n\n(código ' || v_codigo || ')';
    end if;

    v_ok := false;
    v_motivo := 'SEM_OPERADORA';

    for v_op in select o.* from app.operator_contacts o where o.active loop
      -- A conversa dela num numero ligado: de preferencia no proprio salao do
      -- alerta, senao a mais recente.
      select c.id, c.tenant_id into v_conv
        from app.crm_conversations c
        join app.channel_connections ch
          on ch.id = c.channel_connection_id and ch.tenant_id = c.tenant_id
       where app.chave_do_telefone(c.external_conversation_ref) = app.chave_do_telefone(v_op.phone_digits)
         and ch.status not in ('DISCONNECTED', 'SUSPENDED')
       order by (c.tenant_id = v_a.tenant_id) desc, c.last_inbound_at desc nulls last
       limit 1;

      if not found then
        v_motivo := 'OPERADORA_SEM_CONVERSA';
        continue;
      end if;

      v_r := app.enqueue_outbound_message(
        v_conv.tenant_id, v_conv.id, v_texto, 'SYSTEM'::app.outbound_actor,
        'alerta:' || v_a.id::text || case when v_volta then ':volta' else '' end,
        null, null, null, null);

      if coalesce(v_r->>'reason', '') = 'SERVICE_WINDOW_CLOSED' then
        v_r := app.enqueue_outbound_template(
          v_conv.tenant_id, v_conv.id, 'ALERTA_DA_OPERACAO',
          jsonb_build_array(v_salao, left(regexp_replace(v_curto, '\s+', ' ', 'g'), 700), v_codigo),
          'alerta-modelo:' || v_a.id::text || case when v_volta then ':volta' else '' end,
          v_texto);
        if not coalesce((v_r->>'ok')::boolean, false) then
          v_r := app.enqueue_outbound_template(
            v_conv.tenant_id, v_conv.id, 'AVISO_AO_DONO',
            jsonb_build_array(v_salao, 'Sistema', left(regexp_replace(v_curto, '\s+', ' ', 'g'), 700), '#' || v_codigo),
            'alerta-aviso:' || v_a.id::text || case when v_volta then ':volta' else '' end,
            v_texto);
        end if;
      end if;

      if coalesce((v_r->>'ok')::boolean, false) then
        v_ok := true;
      else
        v_motivo := coalesce(v_r->>'reason', 'ERRO');
      end if;
    end loop;

    if v_ok then
      v_enviados := v_enviados + 1;
      if v_volta then
        update app.agent_alerts set volta_avisada_em = statement_timestamp(), aviso_falhou = null
         where id = v_a.id;
      else
        update app.agent_alerts
           set notified_at = statement_timestamp(), aviso_falhou = null,
               resolved_at = case when app.alerta_de_uma_vez(kind) then statement_timestamp() else resolved_at end
         where id = v_a.id;
      end if;
    else
      v_falhas := v_falhas + 1;
      update app.agent_alerts set aviso_falhou = v_motivo where id = v_a.id;
    end if;
  end loop;

  return jsonb_build_object('enviados', v_enviados, 'falhas', v_falhas);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. AS TRAVAS DO CODIGO VIRAM ALERTA
-- ---------------------------------------------------------------------------
create or replace function public.alertar_operadora(p_tenant_id uuid, p_kind text, p_detail text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if p_kind is null or p_kind !~ '^[A-Z_]{3,40}$' then
    raise exception 'tipo de alerta invalido: %', p_kind;
  end if;
  return app.raise_agent_alert(p_tenant_id, p_kind, p_detail);
end;
$function$;

revoke all on function app.e_da_operadora(text) from public, anon, authenticated;
revoke all on function app.operadora_dona_do_salao(uuid, text) from public, anon, authenticated;
revoke all on function app.pausar_conversa_da_operadora() from public, anon, authenticated;
revoke all on function app.record_agent_failure(uuid, uuid, text, boolean) from public, anon, authenticated;
revoke all on function app.clear_agent_failures(uuid, uuid) from public, anon, authenticated;
revoke all on function app.avisar_operadora() from public, anon, authenticated;
revoke all on function public.alertar_operadora(uuid, text, text) from public, anon, authenticated;
grant execute on function public.alertar_operadora(uuid, text, text) to service_role;

select cron.schedule('avisar-operadora', '* * * * *', $c$ select app.avisar_operadora(); $c$);
