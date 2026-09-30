-- O AGENDAMENTO VAI PARA O GOOGLE AGENDA.
--
-- 29/09/2026 (G4). A conexao com o Google ja pedia permissao de escrita desde
-- 26/09, mas nada escrevia: a cliente marcava pelo WhatsApp e o dono so via
-- o horario no painel. Quem trabalha olhando o Google no celular ficava sem
-- saber da cliente.
--
-- Como funciona:
--   * todo agendamento que nasce, muda de horario ou muda de situacao entra
--     numa fila (app.agenda_gravacoes), uma linha por agenda de destino;
--   * destino = a agenda de quem atende (cada profissional do plano) + a
--     agenda do dono (o dono ve tudo) + a agenda do salao (conexao sem nome);
--   * CONFIRMADO/CONCLUIDO -> o evento existe; CANCELADO/FALTOU/AGUARDANDO
--     SINAL -> o evento nao existe (sinal: o horario so vai para a agenda
--     depois de pago);
--   * o worker AGENDA_GRAVA (a cada minuto, so quando ha fila) escreve no
--     Google e marca a linha como feita.
--
-- O evento leva `origem=eddigital` nas propriedades privadas: a leitura de
-- 15 em 15 minutos pula esses eventos, senao o agendamento ocuparia o
-- horario duas vezes. E o id do evento e derivado do id do agendamento, para
-- que gravar duas vezes nunca crie dois eventos.

create table if not exists app.agenda_gravacoes (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references app.tenants(id) on delete cascade,
  appointment_id   uuid not null references app.appointments(id) on delete cascade,
  connection_id    uuid not null references app.calendar_connections(id) on delete cascade,
  deve_existir     boolean not null,
  pendente         boolean not null default true,
  google_event_id  text,
  tentativas       integer not null default 0,
  ultimo_erro      text,
  gravado_em       timestamptz,
  criado_em        timestamptz not null default statement_timestamp(),
  atualizado_em    timestamptz not null default statement_timestamp(),
  unique (appointment_id, connection_id)
);

create index if not exists agenda_gravacoes_pendentes
  on app.agenda_gravacoes (atualizado_em) where pendente;

alter table app.agenda_gravacoes enable row level security;
-- Sem politica: so as funcoes abaixo (SECURITY DEFINER) leem e escrevem.

comment on table app.agenda_gravacoes is
  'Fila do que precisa ser escrito/apagado no Google Agenda para cada agendamento (G4).';

-- As agendas que devem mostrar um agendamento.
create or replace function app.agenda_destinos(p_appointment_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path to ''
as $fn$
  with a as (
    select * from app.appointments where id = p_appointment_id
  ),
  quem as (
    select distinct app.agenda_nome_comparavel(tm.name) nome
      from a
      cross join lateral jsonb_array_elements(coalesce(a.plan -> 'steps', '[]'::jsonb)) passo
      join app.team_members tm on tm.id::text = passo ->> 'memberId'
  ),
  dono as (
    select app.agenda_nome_comparavel(o.display_name) nome
      from a join app.owner_whatsapp o on o.tenant_id = a.tenant_id and o.status = 'ACTIVE'
  )
  select c.id
    from a
    join app.calendar_connections c on c.tenant_id = a.tenant_id
   where c.provider = 'GOOGLE'
     and c.status in ('ACTIVE', 'ERROR')
     and (c.scope is null or c.scope like '%calendar.events%')
     and (
       c.member_name is null
       or app.agenda_nome_comparavel(c.member_name) in (select nome from quem)
       or app.agenda_nome_comparavel(c.member_name) in (select nome from dono)
     );
$fn$;

-- Poe (ou atualiza) um agendamento na fila.
create or replace function app.agenda_enfileirar(p_appointment_id uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_a       app.appointments%rowtype;
  v_existir boolean;
  v_n       integer := 0;
begin
  select * into v_a from app.appointments where id = p_appointment_id;
  if v_a.id is null then
    return 0;
  end if;
  v_existir := v_a.status in ('CONFIRMED', 'COMPLETED');

  -- Destinos de agora. Evento que nunca foi escrito e nao deve existir
  -- (aguardando sinal, cancelado antes de gravar) nem entra na fila.
  if v_existir then
    insert into app.agenda_gravacoes (tenant_id, appointment_id, connection_id, deve_existir)
    select v_a.tenant_id, v_a.id, d, true from app.agenda_destinos(v_a.id) d
    on conflict (appointment_id, connection_id) do update
      set deve_existir = true, pendente = true, tentativas = 0,
          ultimo_erro = null, atualizado_em = statement_timestamp();
  else
    update app.agenda_gravacoes g
       set deve_existir = false, pendente = true, tentativas = 0, ultimo_erro = null,
           atualizado_em = statement_timestamp()
     where g.appointment_id = v_a.id;
  end if;
  get diagnostics v_n = row_count;

  -- Agenda que deixou de ser destino (trocou de profissional): o evento sai.
  update app.agenda_gravacoes g
     set deve_existir = false, pendente = true, tentativas = 0, ultimo_erro = null,
         atualizado_em = statement_timestamp()
   where g.appointment_id = v_a.id
     and g.connection_id not in (select d from app.agenda_destinos(v_a.id) d)
     and g.deve_existir;

  return v_n;
end;
$fn$;

create or replace function app.agenda_ao_mudar_agendamento()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  perform app.agenda_enfileirar(new.id);
  return new;
end;
$fn$;

drop trigger if exists agenda_google_ao_mudar on app.appointments;
create trigger agenda_google_ao_mudar
  after insert or update of status, starts_at, ends_at, plan, customer_label on app.appointments
  for each row execute function app.agenda_ao_mudar_agendamento();

-- Conexao nova (ou que voltou, ou mudou de agenda): o que ja estava marcado
-- dali para frente tambem vai para la. Mudou de agenda: os eventos antigos
-- ficam na agenda velha e os novos sao criados na nova.
create or replace function app.agenda_ao_mudar_conexao()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if tg_op = 'UPDATE' and new.calendar_id is distinct from old.calendar_id then
    delete from app.agenda_gravacoes where connection_id = new.id;
  end if;
  if new.status = 'ACTIVE' and (
       tg_op = 'INSERT'
       or old.status is distinct from 'ACTIVE'
       or new.calendar_id is distinct from old.calendar_id
       or new.member_name is distinct from old.member_name) then
    perform app.agenda_enfileirar(a.id)
       from app.appointments a
      where a.tenant_id = new.tenant_id
        and a.ends_at > statement_timestamp()
        and a.status in ('CONFIRMED', 'COMPLETED');
  end if;
  return new;
end;
$fn$;

drop trigger if exists agenda_google_ao_mudar_conexao on app.calendar_connections;
create trigger agenda_google_ao_mudar_conexao
  after insert or update of status, calendar_id, member_name on app.calendar_connections
  for each row execute function app.agenda_ao_mudar_conexao();

-- O que o worker precisa para escrever: o evento pronto e a conexao aberta.
create or replace function app.agenda_gravacoes_pendentes(p_limite integer default 20)
returns jsonb
language sql
security definer
set search_path to ''
as $fn$
  select coalesce(jsonb_agg(x order by x ->> 'desde'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'id', g.id,
               'desde', g.atualizado_em,
               'deveExistir', g.deve_existir,
               'googleEventId', coalesce(g.google_event_id, 'ed' || replace(a.id::text, '-', '')),
               'jaGravado', g.google_event_id is not null,
               'appointmentId', a.id,
               'conexao', jsonb_build_object(
                 'id', c.id,
                 'calendarId', c.calendar_id,
                 'accessToken', private.decrypt_calendar_token(c.access_token),
                 'refreshToken', private.decrypt_calendar_token(c.refresh_token),
                 'tokenExpiresAt', c.token_expires_at),
               'evento', jsonb_build_object(
                 'titulo', coalesce(s.nome, 'Atendimento') || ' - ' || coalesce(nullif(a.customer_label, ''), 'Cliente'),
                 'inicio', a.starts_at,
                 'fim', a.ends_at,
                 'fuso', coalesce(u.timezone, 'America/Sao_Paulo'),
                 'descricao', concat_ws(E'\n',
                   case when q.nomes is not null then 'Com ' || q.nomes end,
                   case when a.external_contact_ref is not null then 'WhatsApp da cliente: +' || a.external_contact_ref end,
                   'Marcado pela atendente do WhatsApp.')
               )) x
        from app.agenda_gravacoes g
        join app.appointments a on a.id = g.appointment_id
        join app.calendar_connections c on c.id = g.connection_id
        left join app.units u on u.id = a.unit_id
        left join lateral (
          select sv ->> 'name' nome
            from app.configuration_versions v
            cross join lateral jsonb_array_elements(coalesce(v.snapshot -> 'services', '[]'::jsonb)) sv
           where v.id = a.configuration_version_id and sv ->> 'id' = a.service_id::text
           limit 1) s on true
        left join lateral (
          select string_agg(distinct tm.name, ' e ') nomes
            from jsonb_array_elements(coalesce(a.plan -> 'steps', '[]'::jsonb)) passo
            join app.team_members tm on tm.id::text = passo ->> 'memberId') q on true
       where g.pendente
         and g.tentativas < 8
         and c.status = 'ACTIVE'
         and c.refresh_token is not null
       order by g.atualizado_em
       limit greatest(coalesce(p_limite, 20), 1)
    ) t;
$fn$;

-- O worker devolve o que aconteceu.
create or replace function app.agenda_gravacao_feita(
  p_id                uuid,
  p_google_event_id   text,
  p_existe            boolean,
  p_erro              text,
  p_new_access_token  text,
  p_new_expires_at    timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_g app.agenda_gravacoes%rowtype;
begin
  select * into v_g from app.agenda_gravacoes where id = p_id for update;
  if v_g.id is null then
    return jsonb_build_object('ok', false, 'reason', 'NAO_EXISTE');
  end if;

  if p_new_access_token is not null then
    update app.calendar_connections
       set access_token = private.encrypt_calendar_token(p_new_access_token),
           token_expires_at = coalesce(p_new_expires_at, token_expires_at),
           updated_at = statement_timestamp()
     where id = v_g.connection_id;
  end if;

  if p_erro is not null then
    update app.agenda_gravacoes
       set tentativas = tentativas + 1, ultimo_erro = left(p_erro, 300),
           atualizado_em = statement_timestamp()
     where id = p_id;
    return jsonb_build_object('ok', false, 'erro', p_erro);
  end if;

  -- So baixa a fila se nada mudou desde que o worker leu: se o agendamento
  -- mudou no meio, a linha continua pendente e vai de novo.
  update app.agenda_gravacoes
     set pendente = case when deve_existir = p_existe then false else true end,
         google_event_id = case when p_existe then p_google_event_id else null end,
         gravado_em = statement_timestamp(),
         ultimo_erro = null,
         atualizado_em = statement_timestamp()
   where id = p_id;
  return jsonb_build_object('ok', true);
end;
$fn$;

-- Fachadas para o worker.
create or replace function public.agenda_gravacoes_pendentes(p_limite integer default 20)
returns jsonb language sql security definer set search_path to ''
as $$ select app.agenda_gravacoes_pendentes(p_limite); $$;

create or replace function public.agenda_gravacao_feita(
  p_id uuid, p_google_event_id text, p_existe boolean, p_erro text,
  p_new_access_token text, p_new_expires_at timestamptz)
returns jsonb language sql security definer set search_path to ''
as $$ select app.agenda_gravacao_feita(p_id, p_google_event_id, p_existe, p_erro,
                                        p_new_access_token, p_new_expires_at); $$;

revoke all on function app.agenda_destinos(uuid) from public, anon, authenticated;
revoke all on function app.agenda_enfileirar(uuid) from public, anon, authenticated;
revoke all on function app.agenda_ao_mudar_agendamento() from public, anon, authenticated;
revoke all on function app.agenda_ao_mudar_conexao() from public, anon, authenticated;
revoke all on function app.agenda_gravacoes_pendentes(integer) from public, anon, authenticated;
revoke all on function app.agenda_gravacao_feita(uuid, text, boolean, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.agenda_gravacoes_pendentes(integer) from public, anon, authenticated;
revoke all on function public.agenda_gravacao_feita(uuid, text, boolean, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.agenda_gravacoes_pendentes(integer) to service_role;
grant execute on function public.agenda_gravacao_feita(uuid, text, boolean, text, text, timestamptz) to service_role;

-- O worker que escreve: a cada minuto, e so chama a funcao quando ha fila.
alter table app.worker_runs drop constraint if exists worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR','MODELOS','AGENDA','AGENDA_GRAVA']));
alter table app.worker_heartbeat drop constraint if exists worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR','MODELOS','AGENDA','AGENDA_GRAVA']));

select cron.schedule('agenda-google-grava', '* * * * *',
  $$ select app.tick_worker('AGENDA_GRAVA', 'google-agenda', '{"acao":"gravar"}'::jsonb, 60000)
      where exists (select 1 from app.agenda_gravacoes where pendente and tentativas < 8); $$);

-- O que ja esta marcado dali para frente, nos saloes que ja tem agenda ligada.
select app.agenda_enfileirar(a.id)
  from app.appointments a
 where a.ends_at > statement_timestamp()
   and a.status in ('CONFIRMED', 'COMPLETED')
   and exists (select 1 from app.calendar_connections c
                where c.tenant_id = a.tenant_id and c.provider = 'GOOGLE' and c.status = 'ACTIVE');
