-- O DONO MEXEU NO GOOGLE EM UM HORARIO QUE A ATENDENTE MARCOU.
--
-- 30/09/2026. Ate aqui, apagar ou arrastar no Google o evento de uma cliente
-- nao mudava nada: a leitura de 15 em 15 minutos pula os eventos que nos
-- mesmos escrevemos. O dono achava que tinha desmarcado; a cliente, que nao
-- sabia de nada, aparecia no salao.
--
-- Agora a leitura confere os nossos eventos. Sumiu (ou foi para a lixeira)
-- ou mudou de horario: vira uma "mexida", e o Eddy pergunta ao dono o que
-- fazer. Nada acontece com a cliente sem o dono decidir:
--   APAGADO -> desmarcar e avisar a cliente, ou voltar o evento (sem querer);
--   MOVIDO  -> mudar o horario dela e avisar, ou voltar como era.

create table if not exists app.agenda_mexidas (
  id              uuid primary key default gen_random_uuid(),
  codigo          text not null unique default upper(substr(md5(gen_random_uuid()::text), 1, 4)),
  tenant_id       uuid not null references app.tenants(id) on delete cascade,
  appointment_id  uuid not null references app.appointments(id) on delete cascade,
  connection_id   uuid not null references app.calendar_connections(id) on delete cascade,
  tipo            text not null check (tipo in ('APAGADO', 'MOVIDO')),
  novo_inicio     timestamptz,
  novo_fim        timestamptz,
  detectada_em    timestamptz not null default statement_timestamp(),
  avisado_em      timestamptz,
  resolvida_em    timestamptz,
  resolucao       text
);

create unique index if not exists agenda_mexidas_uma_aberta
  on app.agenda_mexidas (appointment_id) where resolvida_em is null;

alter table app.agenda_mexidas enable row level security;
-- Sem politica: so as funcoes abaixo (SECURITY DEFINER) leem e escrevem.

-- A conversa de WhatsApp do dono (a mesma regra do aviso de "agenda caiu").
create or replace function app.conversa_do_dono(p_tenant_id uuid)
returns uuid
language sql
stable
security definer
set search_path to ''
as $fn$
  select c.id
    from app.crm_conversations c
    join app.owner_whatsapp o
      on o.tenant_id = c.tenant_id and o.status = 'ACTIVE'
     and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8)
         = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 8)
   where c.tenant_id = p_tenant_id
   order by c.last_inbound_at desc nulls last
   limit 1;
$fn$;

-- "qui 08/10 às 09:00", no fuso do salao.
create or replace function app.agenda_quando(p_momento timestamptz, p_unit_id uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $fn$
  select (array['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow from l)::int + 1]
         || ' ' || to_char(l, 'DD/MM') || ' às ' || to_char(l, 'HH24:MI')
    from (select p_momento at time zone coalesce((select u.timezone from app.units u where u.id = p_unit_id),
                                                  'America/Sao_Paulo') l) x;
$fn$;

-- A leitura do Google entrega os NOSSOS eventos que achou, e aqui se compara.
create or replace function app.agenda_conferir_nossos(
  p_connection_id uuid,
  p_window_start  timestamptz,
  p_window_end    timestamptz,
  p_nossos        jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_c        app.calendar_connections%rowtype;
  v_r        record;
  v_n        jsonb;
  v_tipo     text;
  v_ini      timestamptz;
  v_fim      timestamptz;
  v_m        app.agenda_mexidas%rowtype;
  v_conversa uuid;
  v_nome     text;
  v_servico  text;
  v_texto    text;
  v_novas    integer := 0;
begin
  select * into v_c from app.calendar_connections where id = p_connection_id;
  if v_c.id is null then
    return jsonb_build_object('ok', false, 'reason', 'CONEXAO_NAO_EXISTE');
  end if;

  for v_r in
    select g.google_event_id, a.*
      from app.agenda_gravacoes g
      join app.appointments a on a.id = g.appointment_id
     where g.connection_id = p_connection_id
       and g.deve_existir and not g.pendente and g.google_event_id is not null
       -- escrito antes desta leitura comecar: evita corrida com a gravacao
       and g.gravado_em < p_window_start
       and a.status = 'CONFIRMED'
       and a.starts_at >= p_window_start and a.starts_at < p_window_end
  loop
    select e.value into v_n
      from jsonb_array_elements(coalesce(p_nossos, '[]'::jsonb)) e
     where e.value ->> 'id' = v_r.google_event_id
     limit 1;

    v_tipo := null; v_ini := null; v_fim := null;
    if v_n is null or coalesce((v_n ->> 'cancelado')::boolean, false) then
      v_tipo := 'APAGADO';
    elsif abs(extract(epoch from ((v_n ->> 'inicio')::timestamptz - v_r.starts_at))) > 60 then
      v_tipo := 'MOVIDO';
      v_ini := (v_n ->> 'inicio')::timestamptz;
      v_fim := (v_n ->> 'fim')::timestamptz;
    end if;

    if v_tipo is null then
      -- Voltou a bater (o dono desfez no Google): a mexida aberta se resolve sozinha.
      update app.agenda_mexidas set resolvida_em = statement_timestamp(), resolucao = 'DESFEITO_NO_GOOGLE'
       where appointment_id = v_r.id and resolvida_em is null;
      continue;
    end if;

    select * into v_m from app.agenda_mexidas where appointment_id = v_r.id and resolvida_em is null;
    if v_m.id is not null then
      if v_m.tipo = v_tipo and v_m.novo_inicio is not distinct from v_ini then
        continue;  -- ja avisado
      end if;
      update app.agenda_mexidas set resolvida_em = statement_timestamp(), resolucao = 'SUBSTITUIDA'
       where id = v_m.id;
    end if;

    insert into app.agenda_mexidas (tenant_id, appointment_id, connection_id, tipo, novo_inicio, novo_fim)
    values (v_r.tenant_id, v_r.id, p_connection_id, v_tipo, v_ini, v_fim)
    returning * into v_m;
    v_novas := v_novas + 1;

    v_nome := coalesce(split_part(nullif(trim(v_r.customer_label), ''), ' ', 1), 'a cliente');
    select sv ->> 'name' into v_servico
      from app.configuration_versions cv
      cross join lateral jsonb_array_elements(coalesce(cv.snapshot -> 'services', '[]'::jsonb)) sv
     where cv.id = v_r.configuration_version_id and sv ->> 'id' = v_r.service_id::text
     limit 1;

    v_texto := case v_tipo
      when 'APAGADO' then
        'Vi que você apagou do Google o horário de ' || v_nome || ' (' || coalesce(v_servico, 'atendimento') || ', '
        || app.agenda_quando(v_r.starts_at, v_r.unit_id) || '). No sistema continua marcado e a cliente vai vir. '
        || 'Quer que eu desmarque e avise a cliente com educação? Ou foi sem querer e eu coloco de volta na agenda?'
      else
        'Vi que você mudou no Google o horário de ' || v_nome || ' (' || coalesce(v_servico, 'atendimento') || ') de '
        || app.agenda_quando(v_r.starts_at, v_r.unit_id) || ' para ' || app.agenda_quando(v_ini, v_r.unit_id)
        || '. A cliente ainda não sabe e vem no horário antigo. Quer que eu mude o horário e avise a cliente? Ou volto como era?'
    end || ' [' || v_m.codigo || ']';

    v_conversa := app.conversa_do_dono(v_r.tenant_id);
    if v_conversa is not null then
      perform app.enqueue_outbound_message(
        v_r.tenant_id, v_conversa, v_texto, 'SYSTEM'::app.outbound_actor,
        'agenda-mexida:' || v_m.id::text, null, null, null, null);
      update app.agenda_mexidas set avisado_em = statement_timestamp() where id = v_m.id;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'mexidasNovas', v_novas);
end;
$fn$;

-- O dono decidiu. DESMARCAR, MUDAR ou VOLTAR.
create or replace function app.eddy_resolver_mexida(p_tenant_id uuid, p_codigo text, p_acao text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_m        app.agenda_mexidas%rowtype;
  v_a        app.appointments%rowtype;
  v_delta    interval;
  v_conversa uuid;
  v_nome     text;
  v_servico  text;
  v_frente   text;
  v_texto    text;
  v_sinal    integer;
begin
  select * into v_m from app.agenda_mexidas
   where tenant_id = p_tenant_id and codigo = upper(trim(p_codigo)) and resolvida_em is null
   for update;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'MEXIDA_NAO_EXISTE_OU_JA_RESOLVIDA');
  end if;
  select * into v_a from app.appointments where id = v_m.appointment_id for update;
  if v_a.status <> 'CONFIRMED' then
    update app.agenda_mexidas set resolvida_em = statement_timestamp(), resolucao = 'AGENDAMENTO_JA_' || v_a.status
     where id = v_m.id;
    return jsonb_build_object('ok', false, 'reason', 'AGENDAMENTO_NAO_ESTA_MAIS_CONFIRMADO', 'situacao', v_a.status);
  end if;

  v_nome := coalesce(split_part(nullif(trim(v_a.customer_label), ''), ' ', 1), '');
  select sv ->> 'name' into v_servico
    from app.configuration_versions cv
    cross join lateral jsonb_array_elements(coalesce(cv.snapshot -> 'services', '[]'::jsonb)) sv
   where cv.id = v_a.configuration_version_id and sv ->> 'id' = v_a.service_id::text
   limit 1;
  select case when s.equipe_como_um_so then s.equipe_frente end into v_frente
    from app.agent_scope s where s.tenant_id = p_tenant_id;
  select c.id into v_conversa
    from app.crm_conversations c
   where c.tenant_id = p_tenant_id
     and right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 11)
       = right(regexp_replace(coalesce(v_a.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
   order by c.last_inbound_at desc nulls last
   limit 1;

  if upper(p_acao) = 'VOLTAR' then
    update app.agenda_gravacoes
       set deve_existir = true, pendente = true, tentativas = 0, ultimo_erro = null,
           atualizado_em = statement_timestamp()
     where appointment_id = v_a.id and connection_id = v_m.connection_id;
    update app.agenda_mexidas set resolvida_em = statement_timestamp(), resolucao = 'VOLTAR' where id = v_m.id;
    return jsonb_build_object('ok', true, 'feito', 'o evento volta para o Google como era em até 1 minuto; a cliente não foi avisada de nada');
  end if;

  if upper(p_acao) = 'DESMARCAR' then
    select d.amount_cents into v_sinal from app.appointment_deposits d
     where d.appointment_id = v_a.id and d.status = 'CONFIRMED' limit 1;
    update app.appointments set status = 'CANCELLED', updated_at = statement_timestamp() where id = v_a.id;
    update app.member_occupancies set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = v_a.tenant_id and source_type = 'APPOINTMENT' and source_id = v_a.id and status = 'ACTIVE';
    update app.resource_occupancies set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = v_a.tenant_id and source_type = 'APPOINTMENT' and source_id = v_a.id and status = 'ACTIVE';
    update app.appointment_deposits set status = 'CANCELLED'
     where appointment_id = v_a.id and status = 'PENDING';
    v_texto := 'Oi' || case when v_nome <> '' then ', ' || v_nome else '' end || '! Tudo bem? '
      || 'Precisamos desmarcar o seu horário de ' || app.agenda_quando(v_a.starts_at, v_a.unit_id)
      || coalesce(' (' || v_servico || ')', '') || '. Pedimos desculpas pelo transtorno! '
      || 'Se quiser, me fala um dia e horário que eu vejo outra opção pra você.';
    if v_conversa is not null then
      perform app.enqueue_outbound_message(v_a.tenant_id, v_conversa, v_texto, 'AGENT'::app.outbound_actor,
        'mexida-desmarcar:' || v_m.id::text, null, null, null, null);
    end if;
    update app.agenda_mexidas set resolvida_em = statement_timestamp(), resolucao = 'DESMARCAR' where id = v_m.id;
    return jsonb_build_object('ok', true, 'feito', 'desmarcado e cliente avisada', 'mensagemParaCliente', v_texto,
      'clienteAvisada', v_conversa is not null,
      'sinalPagoParaDevolver', case when v_sinal is not null then v_sinal end);
  end if;

  if upper(p_acao) = 'MUDAR' then
    if v_m.tipo <> 'MOVIDO' or v_m.novo_inicio is null then
      return jsonb_build_object('ok', false, 'reason', 'SO_DA_PARA_MUDAR_O_QUE_FOI_MOVIDO');
    end if;
    if v_m.novo_inicio <= statement_timestamp() then
      return jsonb_build_object('ok', false, 'reason', 'NOVO_HORARIO_JA_PASSOU');
    end if;
    v_delta := v_m.novo_inicio - v_a.starts_at;
    begin
      update app.member_occupancies
         set time_range = tstzrange(lower(time_range) + v_delta, upper(time_range) + v_delta, '[)'),
             updated_at = statement_timestamp()
       where tenant_id = v_a.tenant_id and source_type = 'APPOINTMENT' and source_id = v_a.id and status = 'ACTIVE';
      update app.resource_occupancies
         set time_range = tstzrange(lower(time_range) + v_delta, upper(time_range) + v_delta, '[)'),
             updated_at = statement_timestamp()
       where tenant_id = v_a.tenant_id and source_type = 'APPOINTMENT' and source_id = v_a.id and status = 'ACTIVE';
    exception when exclusion_violation then
      return jsonb_build_object('ok', false, 'reason', 'CHOCA_COM_OUTRA_CLIENTE',
        'explicacao', 'nesse novo horário a mesma profissional já tem outra cliente; nada foi mudado');
    end;
    update app.appointments
       set starts_at = starts_at + v_delta, ends_at = ends_at + v_delta,
           plan = coalesce((select jsonb_set(v_a.plan, '{steps}', coalesce(jsonb_agg(
                    p.value || jsonb_build_object(
                      'startMs', (p.value ->> 'startMs')::bigint + (extract(epoch from v_delta) * 1000)::bigint,
                      'endMs',   (p.value ->> 'endMs')::bigint   + (extract(epoch from v_delta) * 1000)::bigint)), '[]'::jsonb))
                  from jsonb_array_elements(coalesce(v_a.plan -> 'steps', '[]'::jsonb)) p), v_a.plan),
           updated_at = statement_timestamp()
     where id = v_a.id;
    v_texto := 'Oi' || case when v_nome <> '' then ', ' || v_nome else '' end || '! Tudo bem? '
      || coalesce(v_frente || ' precisou', 'Precisamos') || ' ajustar o seu horário: '
      || coalesce(v_servico || ' ', '') || 'passou de ' || app.agenda_quando(v_a.starts_at, v_a.unit_id)
      || ' para ' || app.agenda_quando(v_m.novo_inicio, v_a.unit_id) || '. '
      || 'Esse novo horário fica bom pra você? Se não der, me avisa que eu vejo outra opção.';
    if v_conversa is not null then
      perform app.enqueue_outbound_message(v_a.tenant_id, v_conversa, v_texto, 'AGENT'::app.outbound_actor,
        'mexida-mudar:' || v_m.id::text, null, null, null, null);
    end if;
    update app.agenda_mexidas set resolvida_em = statement_timestamp(), resolucao = 'MUDAR' where id = v_m.id;
    return jsonb_build_object('ok', true, 'feito', 'horário mudado e cliente avisada', 'mensagemParaCliente', v_texto,
      'clienteAvisada', v_conversa is not null);
  end if;

  return jsonb_build_object('ok', false, 'reason', 'ACAO_INVALIDA', 'acoes', 'DESMARCAR, MUDAR, VOLTAR');
end;
$fn$;

-- O que o Eddy ve: as mexidas abertas do salao.
create or replace function app.eddy_mexidas_abertas(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'codigo', m.codigo,
           'tipo', m.tipo,
           'cliente', a.customer_label,
           'horarioMarcado', app.agenda_quando(a.starts_at, a.unit_id),
           'novoHorarioNoGoogle', case when m.novo_inicio is not null then app.agenda_quando(m.novo_inicio, a.unit_id) end,
           'acoesPossiveis', case m.tipo when 'APAGADO' then 'DESMARCAR ou VOLTAR' else 'MUDAR, DESMARCAR ou VOLTAR' end
         ) order by m.detectada_em), '[]'::jsonb)
    from app.agenda_mexidas m
    join app.appointments a on a.id = m.appointment_id
   where m.tenant_id = p_tenant_id and m.resolvida_em is null;
$fn$;

create or replace function public.agenda_conferir_nossos(
  p_connection_id uuid, p_window_start timestamptz, p_window_end timestamptz, p_nossos jsonb)
returns jsonb language sql security definer set search_path to ''
as $$ select app.agenda_conferir_nossos(p_connection_id, p_window_start, p_window_end, p_nossos); $$;

create or replace function public.eddy_resolver_mexida(p_tenant_id uuid, p_codigo text, p_acao text)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_resolver_mexida(p_tenant_id, p_codigo, p_acao); $$;

create or replace function public.eddy_mexidas_abertas(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.eddy_mexidas_abertas(p_tenant_id); $$;

revoke all on function app.conversa_do_dono(uuid) from public, anon, authenticated;
revoke all on function app.agenda_quando(timestamptz, uuid) from public, anon, authenticated;
revoke all on function app.agenda_conferir_nossos(uuid, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function app.eddy_resolver_mexida(uuid, text, text) from public, anon, authenticated;
revoke all on function app.eddy_mexidas_abertas(uuid) from public, anon, authenticated;
revoke all on function public.agenda_conferir_nossos(uuid, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function public.eddy_resolver_mexida(uuid, text, text) from public, anon, authenticated;
revoke all on function public.eddy_mexidas_abertas(uuid) from public, anon, authenticated;
grant execute on function public.agenda_conferir_nossos(uuid, timestamptz, timestamptz, jsonb) to service_role;
grant execute on function public.eddy_resolver_mexida(uuid, text, text) to service_role;
grant execute on function public.eddy_mexidas_abertas(uuid) to service_role;