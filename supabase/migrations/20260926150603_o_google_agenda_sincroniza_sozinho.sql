-- O GOOGLE AGENDA SINCRONIZA SOZINHO, E CADA EVENTO VIRA A COISA CERTA.
--
-- 26/09/2026. A conexao com o Google existia desde agosto, mas:
--   1. so sincronizava quando alguem apertava "Sincronizar agora" no site;
--   2. o app do Google estava em "Teste", e em Teste o Google derruba a
--      permissao a cada 7 dias -- as duas conexoes do piloto morreram com
--      `invalid_grant` (o app foi publicado hoje);
--   3. todo evento virava bloqueio. "Duda vai trabalhar" -- o jeito que a
--      dona marca o dia da profissional sem dia fixo -- bloquearia a agenda
--      exatamente no dia em que a Duda vem.
--
-- A regra, combinada com a dona em 25/09, olhando a agenda real dela:
--   * titulo com "trabalh" + nome de alguem da equipe -> DIA DE TRABALHO
--     dessa pessoa, no horario do salao naquele dia (o horario do evento e
--     lembrete: os dela vao das 6h as 7h);
--   * evento marcado "Livre" no Google -> ignorado (as provas dela estao assim);
--   * evento de dia inteiro -> ignorado (aniversario, feriado);
--   * evento particular -> bloqueia, SEM guardar o titulo;
--   * o resto -> bloqueia so a dona da agenda conectada.
--
-- O dia de trabalho nao vai para member_dynamic_shifts: aquela tabela e do
-- rascunho e so chega ao motor depois de publicar. Evento do Google tem que
-- valer na hora; fica aqui, com `kind`, e o motor le ao vivo.

alter table app.member_calendar_shifts
  add column if not exists kind text not null default 'OCUPADO',
  add column if not exists shift_date date;

alter table app.member_calendar_shifts drop constraint if exists member_calendar_shifts_kind_check;
alter table app.member_calendar_shifts add constraint member_calendar_shifts_kind_check
  check (kind in ('OCUPADO', 'TRABALHO'));

alter table app.calendar_connections
  add column if not exists dono_avisado_em timestamptz;

-- Nome comparavel: minusculo e sem acento.
create or replace function app.agenda_nome_comparavel(p text)
returns text
language sql
immutable
set search_path to ''
as $fn$
  select translate(lower(coalesce(p, '')),
                   'áàâãäéèêëíìîïóòôõöúùûüç',
                   'aaaaaeeeeiiiiooooouuuuc');
$fn$;

-- 1. AS CONEXOES QUE ESTAO NA VEZ DE SINCRONIZAR, COM O TOKEN ABERTO.
-- So o worker chama (service_role). O token decifrado nunca sai daqui para
-- outro lugar que nao a funcao que fala com o Google.
create or replace function app.agenda_conexoes_para_sincronizar(p_limite integer default 20)
returns jsonb
language sql
security definer
set search_path to ''
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'tenantId', c.tenant_id,
           'calendarId', c.calendar_id,
           'accessToken', private.decrypt_calendar_token(c.access_token),
           'refreshToken', private.decrypt_calendar_token(c.refresh_token),
           'tokenExpiresAt', c.token_expires_at
         )), '[]'::jsonb)
    from (
      select c.*
        from app.calendar_connections c
       where c.provider = 'GOOGLE'
         and c.status = 'ACTIVE'
         and c.refresh_token is not null
         and (c.last_synced_at is null or c.last_synced_at < statement_timestamp() - interval '10 minutes')
       order by c.last_synced_at nulls first
       limit greatest(coalesce(p_limite, 20), 1)
    ) c;
$fn$;

-- 2. GRAVA O RESULTADO, APLICANDO A REGRA.
create or replace function app.agenda_gravar_sincronizacao(
  p_connection_id    uuid,
  p_window_start     timestamptz,
  p_window_end       timestamptz,
  p_eventos          jsonb,
  p_new_access_token text,
  p_new_expires_at   timestamptz,
  p_erro             text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_c         app.calendar_connections%rowtype;
  v_fuso      text;
  v_rascunho  uuid;
  v_dono      text;
  v_ev        record;
  v_membro    text;
  v_dia       date;
  v_abre      time;
  v_fecha     time;
  v_trab      integer := 0;
  v_ocup      integer := 0;
  v_ignor     integer := 0;
  v_conversa  uuid;
begin
  select * into v_c from app.calendar_connections where id = p_connection_id for update;
  if v_c.id is null then
    return jsonb_build_object('ok', false, 'reason', 'CONEXAO_NAO_EXISTE');
  end if;

  if p_erro is not null then
    update app.calendar_connections
       set status = 'ERROR', last_error = left(p_erro, 300), updated_at = statement_timestamp()
     where id = v_c.id;

    -- A dona fica sabendo, uma vez. Agenda que parou de sincronizar em
    -- silencio foi exatamente o que aconteceu em agosto.
    if v_c.dono_avisado_em is null or v_c.dono_avisado_em < statement_timestamp() - interval '1 day' then
      select c.id into v_conversa
        from app.crm_conversations c
        join app.owner_whatsapp o
          on o.tenant_id = c.tenant_id and o.status = 'ACTIVE'
         and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8)
             = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 8)
       where c.tenant_id = v_c.tenant_id
       order by c.last_inbound_at desc nulls last
       limit 1;
      if v_conversa is not null then
        perform app.enqueue_outbound_message(
          v_c.tenant_id, v_conversa,
          'Sua agenda do Google parou de conversar comigo (o Google pediu para conectar de novo). '
          || 'Enquanto isso, não vejo seus compromissos nem os dias marcados lá. Me responda "conectar agenda" que eu te mando o link.',
          'SYSTEM'::app.outbound_actor,
          'agenda-caiu:' || v_c.id::text || ':' || to_char(statement_timestamp(), 'YYYYMMDD'),
          null, null, null, null);
        update app.calendar_connections set dono_avisado_em = statement_timestamp() where id = v_c.id;
      end if;
    end if;
    return jsonb_build_object('ok', false, 'erro', p_erro);
  end if;

  select u.timezone into v_fuso from app.units u where u.id = v_c.unit_id;
  v_fuso := coalesce(v_fuso, 'America/Sao_Paulo');

  select d.id into v_rascunho
    from app.configuration_drafts d
   where d.tenant_id = v_c.tenant_id and d.unit_id = v_c.unit_id
   order by d.updated_at desc
   limit 1;

  -- De quem e esta agenda. Sem nome, o motor bloqueia a equipe inteira (e o
  -- certo para "agenda do salao"); a conexao da dona tem que dizer que e dela.
  v_dono := v_c.member_name;
  if v_dono is null then
    select tm.name into v_dono
      from app.team_members tm
      join app.owner_whatsapp o on o.tenant_id = tm.tenant_id and o.status = 'ACTIVE'
     where tm.tenant_id = v_c.tenant_id
       and tm.configuration_draft_id = v_rascunho
       and tm.status = 'ACTIVE'
       and app.agenda_nome_comparavel(tm.name) = app.agenda_nome_comparavel(o.display_name)
     limit 1;
  end if;

  delete from app.member_calendar_shifts
   where connection_id = v_c.id
     and time_range && tstzrange(p_window_start, p_window_end, '[)');

  for v_ev in
    select * from jsonb_to_recordset(coalesce(p_eventos, '[]'::jsonb)) as x(
      id text, titulo text, inicio timestamptz, fim timestamptz, dia text,
      dia_inteiro boolean, livre boolean, particular boolean)
  loop
    -- DIA DE TRABALHO: "trabalh" + nome de alguem da equipe.
    v_membro := null;
    if app.agenda_nome_comparavel(v_ev.titulo) like '%trabalh%' then
      select tm.name into v_membro
        from app.team_members tm
       where tm.tenant_id = v_c.tenant_id
         and tm.configuration_draft_id = v_rascunho
         and tm.status = 'ACTIVE'
         and app.agenda_nome_comparavel(v_ev.titulo)
             ~ ('(^|[^a-z])' || app.agenda_nome_comparavel(tm.name) || '([^a-z]|$)')
       order by length(tm.name) desc
       limit 1;
    end if;

    if v_membro is not null then
      v_dia := coalesce(nullif(v_ev.dia, '')::date, (v_ev.inicio at time zone v_fuso)::date);
      select min(oh.starts_at), max(oh.ends_at) into v_abre, v_fecha
        from app.operating_hours oh
       where oh.configuration_draft_id = v_rascunho
         and oh.weekday = extract(dow from v_dia)::smallint;
      if v_abre is null then
        v_ignor := v_ignor + 1;  -- salao fechado nesse dia: nao inventa horario
        continue;
      end if;
      insert into app.member_calendar_shifts (
        tenant_id, unit_id, connection_id, member_name, external_event_id,
        time_range, title, kind, shift_date
      ) values (
        v_c.tenant_id, v_c.unit_id, v_c.id, v_membro, v_ev.id,
        tstzrange((v_dia + v_abre) at time zone v_fuso, (v_dia + v_fecha) at time zone v_fuso, '[)'),
        v_ev.titulo, 'TRABALHO', v_dia
      )
      on conflict (connection_id, external_event_id) do update
        set time_range = excluded.time_range, title = excluded.title, kind = excluded.kind,
            member_name = excluded.member_name, shift_date = excluded.shift_date,
            synced_at = statement_timestamp();
      v_trab := v_trab + 1;
      continue;
    end if;

    if coalesce(v_ev.dia_inteiro, false) or coalesce(v_ev.livre, false)
       or v_ev.inicio is null or v_ev.fim is null or v_ev.fim <= v_ev.inicio then
      v_ignor := v_ignor + 1;
      continue;
    end if;

    insert into app.member_calendar_shifts (
      tenant_id, unit_id, connection_id, member_name, external_event_id, time_range, title, kind
    ) values (
      v_c.tenant_id, v_c.unit_id, v_c.id, v_dono, v_ev.id,
      tstzrange(v_ev.inicio, v_ev.fim, '[)'),
      case when coalesce(v_ev.particular, false) then null else v_ev.titulo end,
      'OCUPADO'
    )
    on conflict (connection_id, external_event_id) do update
      set time_range = excluded.time_range, title = excluded.title, kind = excluded.kind,
          member_name = excluded.member_name, shift_date = null,
          synced_at = statement_timestamp();
    v_ocup := v_ocup + 1;
  end loop;

  update app.calendar_connections
     set status = 'ACTIVE',
         last_synced_at = statement_timestamp(),
         last_error = null,
         dono_avisado_em = null,
         access_token = coalesce(private.encrypt_calendar_token(p_new_access_token), access_token),
         token_expires_at = coalesce(p_new_expires_at, token_expires_at),
         updated_at = statement_timestamp()
   where id = v_c.id;

  return jsonb_build_object('ok', true, 'diasDeTrabalho', v_trab, 'bloqueios', v_ocup,
                            'ignorados', v_ignor, 'donoDaAgenda', v_dono);
end;
$fn$;

-- 3. O MOTOR: bloqueio continua vindo de schedule_list_calendar_shifts, mas
-- so o que e OCUPADO. Dia de trabalho vem por uma funcao propria.
create or replace function public.schedule_list_calendar_shifts(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'startMs', floor(extract(epoch from lower(s.time_range)) * 1000),
      'endMs',   floor(extract(epoch from upper(s.time_range)) * 1000),
      -- Nulo aqui quer dizer "agenda do salao", e ai bloquear todo mundo e o
      -- certo: o salao fechou naquele horario. Nome preenchido quer dizer
      -- "agenda de uma pessoa", e ai so ela some.
      'memberName', s.member_name
    ) order by lower(s.time_range))
    from app.member_calendar_shifts s
    where s.tenant_id = target_tenant_id and s.unit_id = target_unit_id
      -- Dia de trabalho NAO e bloqueio. Sem este filtro, "Duda vai
      -- trabalhar" apagaria a Duda justamente no dia em que ela vem.
      and s.kind = 'OCUPADO'
  ), '[]'::jsonb);
end;
$function$;

create or replace function public.schedule_list_calendar_workdays(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_fuso text;
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);
  select coalesce(u.timezone, 'America/Sao_Paulo') into v_fuso from app.units u where u.id = target_unit_id;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'memberName', s.member_name,
      'shift_date', s.shift_date,
      'starts_at', to_char(lower(s.time_range) at time zone v_fuso, 'HH24:MI:SS'),
      'ends_at',   to_char(upper(s.time_range) at time zone v_fuso, 'HH24:MI:SS')
    ) order by s.shift_date)
    from app.member_calendar_shifts s
    where s.tenant_id = target_tenant_id and s.unit_id = target_unit_id
      and s.kind = 'TRABALHO' and s.shift_date is not null
  ), '[]'::jsonb);
end;
$function$;

-- 4. Fachadas para o worker (o PostgREST so expoe public).
create or replace function public.agenda_conexoes_para_sincronizar(p_limite integer default 20)
returns jsonb language sql security definer set search_path to ''
as $$ select app.agenda_conexoes_para_sincronizar(p_limite); $$;

create or replace function public.agenda_gravar_sincronizacao(
  p_connection_id uuid, p_window_start timestamptz, p_window_end timestamptz, p_eventos jsonb,
  p_new_access_token text, p_new_expires_at timestamptz, p_erro text)
returns jsonb language sql security definer set search_path to ''
as $$ select app.agenda_gravar_sincronizacao(p_connection_id, p_window_start, p_window_end, p_eventos,
                                              p_new_access_token, p_new_expires_at, p_erro); $$;

revoke all on function app.agenda_conexoes_para_sincronizar(integer) from public, anon, authenticated;
revoke all on function app.agenda_gravar_sincronizacao(uuid, timestamptz, timestamptz, jsonb, text, timestamptz, text) from public, anon, authenticated;
revoke all on function public.agenda_conexoes_para_sincronizar(integer) from public, anon, authenticated;
revoke all on function public.agenda_gravar_sincronizacao(uuid, timestamptz, timestamptz, jsonb, text, timestamptz, text) from public, anon, authenticated;
revoke all on function public.schedule_list_calendar_shifts(text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.schedule_list_calendar_workdays(text, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.agenda_conexoes_para_sincronizar(integer) to service_role;
grant execute on function public.agenda_gravar_sincronizacao(uuid, timestamptz, timestamptz, jsonb, text, timestamptz, text) to service_role;
grant execute on function public.schedule_list_calendar_shifts(text, text, uuid, uuid) to service_role;
grant execute on function public.schedule_list_calendar_workdays(text, text, uuid, uuid) to service_role;

-- 5. O worker AGENDA, de 15 em 15 minutos.
alter table app.worker_runs drop constraint if exists worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR','MODELOS','AGENDA']));
alter table app.worker_heartbeat drop constraint if exists worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR','MODELOS','AGENDA']));

select cron.schedule('agenda-google', '*/15 * * * *',
  $$ select app.tick_worker('AGENDA', 'google-agenda', '{}'::jsonb, 120000); $$);
