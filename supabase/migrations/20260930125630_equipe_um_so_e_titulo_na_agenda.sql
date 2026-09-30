-- A EQUIPE E UMA SO OU SAO PROFISSIONAIS SEPARADOS.
--
-- 30/09/2026. No William, quem marca e o William: as assistentes (Karen,
-- Duda) fazem por ele, e a cliente nao escolhe profissional. Ja em outros
-- saloes cada profissional tem a sua clientela. A atendente precisava saber
-- qual e o caso:
--   * UM SO: a cliente ouve "tenho quarta as 16h" com o nome da frente
--     (William), mesmo que quem esteja livre seja uma assistente;
--   * SEPARADOS: cada horario sai com o nome de quem faz, e "com o William"
--     so procura o William.
-- Vale na hora (como o lembrete), sem publicar. Nulo = o Eddy ainda nao
-- perguntou; a atendente trata como SEPARADOS, que e o que nao engana.

alter table app.agent_scope
  add column if not exists equipe_como_um_so boolean,
  add column if not exists equipe_frente text;


-- E COMO O AGENDAMENTO APARECE NO GOOGLE AGENDA E ESCOLHA DO DONO.
--
-- 30/09/2026. Cada dono le a agenda de um jeito: o William quer
-- "CAROL 16-99425-8547 - LUZES (450 DEU 50 FICOU 400)", outro quer so
-- "Carol - Luzes". O Eddy mostra modelos com exemplo e grava o escolhido.
-- Lacunas: {nome} {telefone} {servico} {valor} {pagamento} {profissional}.
-- {pagamento} = "450 DEU 50 FICOU 400" quando o sinal foi pago, "450" quando
-- nao houve sinal. Nulo = ainda nao escolhido (usa "{nome} {telefone} - {servico}").
alter table app.agent_scope
  add column if not exists agenda_titulo_modelo text,
  add column if not exists agenda_titulo_caixa_alta boolean not null default false;

comment on column app.agent_scope.equipe_como_um_so is
  'true: a cliente ve o salao como um profissional so (equipe_frente). false: profissionais separados. null: ainda nao perguntado.';

create or replace function app.eddy_definir_modo_da_equipe(p_tenant_id uuid, p_um_so boolean, p_frente text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
  v_frente   text;
begin
  select d.id into v_rascunho from app.configuration_drafts d
   where d.tenant_id = p_tenant_id order by d.revision desc limit 1;

  if p_um_so then
    if nullif(trim(p_frente), '') is null then
      -- Sem nome: a frente e o dono.
      select tm.name into v_frente
        from app.team_members tm
        join app.owner_whatsapp o on o.tenant_id = tm.tenant_id and o.status = 'ACTIVE'
       where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'
         and app.agenda_nome_comparavel(tm.name) = app.agenda_nome_comparavel(o.display_name)
       limit 1;
    else
      select tm.name into v_frente
        from app.team_members tm
       where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'
         and app.agenda_nome_comparavel(tm.name) = app.agenda_nome_comparavel(trim(p_frente))
       limit 1;
    end if;
    if v_frente is null then
      return jsonb_build_object('ok', false, 'reason', 'FRENTE_NAO_ESTA_NA_EQUIPE',
        'equipe', (select to_jsonb(array_agg(tm.name order by tm.name)) from app.team_members tm
                    where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'));
    end if;
  end if;

  update app.agent_scope
     set equipe_como_um_so = p_um_so,
         equipe_frente = case when p_um_so then v_frente else null end,
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_SEM_ESCOPO');
  end if;

  return jsonb_build_object('ok', true, 'umSo', p_um_so, 'frente', v_frente,
                            'vale', 'na hora, sem publicar');
end;
$fn$;

create or replace function public.eddy_definir_modo_da_equipe(p_tenant_id uuid, p_um_so boolean, p_frente text default null)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_definir_modo_da_equipe(p_tenant_id, p_um_so, p_frente); $$;

-- O que a atendente precisa saber, por conversa.
create or replace function app.agente_modo_da_equipe(p_conversation_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  select jsonb_build_object('umSo', coalesce(a.equipe_como_um_so, false), 'frente', a.equipe_frente)
    from app.crm_conversations c
    join app.agent_scope a on a.tenant_id = c.tenant_id
   where c.id = p_conversation_id
   limit 1;
$fn$;

create or replace function public.agente_modo_da_equipe(p_conversation_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.agente_modo_da_equipe(p_conversation_id); $$;


-- Os valores de um agendamento, para montar o titulo.
create or replace function app.agenda_valores_do_agendamento(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  select jsonb_build_object(
    'nome', coalesce(split_part(nullif(trim(a.customer_label), ''), ' ', 1), 'Cliente'),
    'telefone', case
      when length(d.dig) >= 12 and left(d.dig, 2) = '55'
        then substr(d.dig, 3, 2) || '-' || substr(d.dig, 5, length(d.dig) - 8) || '-' || right(d.dig, 4)
      when length(d.dig) >= 10
        then substr(d.dig, 1, 2) || '-' || substr(d.dig, 3, length(d.dig) - 6) || '-' || right(d.dig, 4)
      else coalesce(nullif(d.dig, ''), '') end,
    'servico', coalesce(s.nome, 'Atendimento'),
    'valorCentavos', p.preco,
    'sinalPagoCentavos', (select dp.amount_cents from app.appointment_deposits dp
                           where dp.appointment_id = a.id and dp.status = 'CONFIRMED' limit 1),
    'profissional', q.nomes)
  from app.appointments a
  cross join lateral (select regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g') dig) d
  left join lateral (
    select sv ->> 'name' nome, sv
      from app.configuration_versions v
      cross join lateral jsonb_array_elements(coalesce(v.snapshot -> 'services', '[]'::jsonb)) sv
     where v.id = a.configuration_version_id and sv ->> 'id' = a.service_id::text
     limit 1) s on true
  left join lateral (
    select coalesce(
             case when a.variation_id is null then null else (
               select (va ->> 'price_minor')::integer
                 from jsonb_array_elements(coalesce(s.sv -> 'variations', '[]'::jsonb)) va
                where va ->> 'id' = a.variation_id::text limit 1) end,
             (s.sv ->> 'base_price_minor')::integer) preco) p on true
  left join lateral (
    select string_agg(distinct tm.name, ' e ') nomes
      from jsonb_array_elements(coalesce(a.plan -> 'steps', '[]'::jsonb)) passo
      join app.team_members tm on tm.id::text = passo ->> 'memberId') q on true
  where a.id = p_appointment_id;
$fn$;

-- Reais sem centavos quando redondo: 45000 -> "450"; 45050 -> "450,50".
create or replace function app.agenda_reais_curto(p_centavos integer)
returns text language sql immutable set search_path to ''
as $fn$
  select case when p_centavos is null then null
              when p_centavos % 100 = 0 then (p_centavos / 100)::text
              else (p_centavos / 100)::text || ',' || lpad((p_centavos % 100)::text, 2, '0') end;
$fn$;

-- Aplica um modelo a um conjunto de valores. Usada no titulo de verdade e no
-- exemplo que o Eddy mostra ao dono -- o mesmo codigo, para o exemplo nunca
-- mentir sobre como vai ficar.
create or replace function app.agenda_aplicar_modelo(p_modelo text, p_caixa_alta boolean, p_v jsonb)
returns text language plpgsql immutable set search_path to ''
as $fn$
declare
  v_valor  text := app.agenda_reais_curto((p_v ->> 'valorCentavos')::integer);
  v_sinal  integer := (p_v ->> 'sinalPagoCentavos')::integer;
  v_pag    text;
  v_t      text;
begin
  v_pag := case
    when v_valor is null then ''
    when v_sinal is not null and v_sinal > 0 then
      v_valor || ' DEU ' || app.agenda_reais_curto(v_sinal) || ' FICOU '
      || app.agenda_reais_curto(greatest((p_v ->> 'valorCentavos')::integer - v_sinal, 0))
    else v_valor end;
  v_t := coalesce(nullif(trim(p_modelo), ''), '{nome} {telefone} - {servico}');
  v_t := replace(v_t, '{nome}', coalesce(p_v ->> 'nome', ''));
  v_t := replace(v_t, '{telefone}', coalesce(p_v ->> 'telefone', ''));
  v_t := replace(v_t, '{servico}', coalesce(p_v ->> 'servico', ''));
  v_t := replace(v_t, '{valor}', coalesce(v_valor, ''));
  v_t := replace(v_t, '{pagamento}', v_pag);
  v_t := replace(v_t, '{profissional}', coalesce(p_v ->> 'profissional', ''));
  -- Lacuna sem valor nao deixa "()" nem espaco duplo para tras.
  v_t := regexp_replace(v_t, '\(\s*\)', '', 'g');
  v_t := regexp_replace(v_t, '\s{2,}', ' ', 'g');
  v_t := regexp_replace(v_t, '\s*-\s*$', '');
  v_t := trim(v_t);
  return case when p_caixa_alta then upper(v_t) else v_t end;
end;
$fn$;

create or replace function app.agenda_titulo(p_appointment_id uuid)
returns text language sql stable security definer set search_path to ''
as $fn$
  select app.agenda_aplicar_modelo(sc.agenda_titulo_modelo, sc.agenda_titulo_caixa_alta,
                                   app.agenda_valores_do_agendamento(a.id))
    from app.appointments a
    left join app.agent_scope sc on sc.tenant_id = a.tenant_id
   where a.id = p_appointment_id;
$fn$;

-- O Eddy grava o modelo que o dono escolheu e ve o exemplo pronto.
create or replace function app.eddy_definir_titulo_agenda(p_tenant_id uuid, p_modelo text, p_caixa_alta boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_sobra text;
  v_n     integer;
begin
  if nullif(trim(p_modelo), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'MODELO_VAZIO');
  end if;
  v_sobra := regexp_replace(p_modelo, '\{(nome|telefone|servico|valor|pagamento|profissional)\}', '', 'g');
  if v_sobra ~ '[{}]' then
    return jsonb_build_object('ok', false, 'reason', 'LACUNA_DESCONHECIDA',
      'permitidas', '{nome} {telefone} {servico} {valor} {pagamento} {profissional}');
  end if;
  update app.agent_scope
     set agenda_titulo_modelo = trim(p_modelo), agenda_titulo_caixa_alta = coalesce(p_caixa_alta, false),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_SEM_ESCOPO');
  end if;
  -- O que ja esta marcado dali para frente e reescrito com o modelo novo.
  perform app.agenda_enfileirar(a.id) from app.appointments a
   where a.tenant_id = p_tenant_id and a.ends_at > statement_timestamp()
     and a.status in ('CONFIRMED', 'COMPLETED');
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true,
    'comSinal', app.agenda_aplicar_modelo(p_modelo, p_caixa_alta,
       '{"nome":"Carol","telefone":"16-99425-8547","servico":"Luzes","valorCentavos":45000,"sinalPagoCentavos":5000,"profissional":"Duda"}'),
    'semSinal', app.agenda_aplicar_modelo(p_modelo, p_caixa_alta,
       '{"nome":"Carol","telefone":"16-99425-8547","servico":"Luzes","valorCentavos":45000,"profissional":"Duda"}'),
    'agendamentosReescritos', v_n);
end;
$fn$;

create or replace function public.eddy_definir_titulo_agenda(p_tenant_id uuid, p_modelo text, p_caixa_alta boolean)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_definir_titulo_agenda(p_tenant_id, p_modelo, p_caixa_alta); $$;

-- Sinal pago muda o titulo ("DEU 50 FICOU 400"): o evento e reescrito.
create or replace function app.agenda_ao_mudar_sinal()
returns trigger language plpgsql security definer set search_path to ''
as $fn$
begin
  perform app.agenda_enfileirar(new.appointment_id);
  return new;
end;
$fn$;

drop trigger if exists agenda_google_ao_mudar_sinal on app.appointment_deposits;
create trigger agenda_google_ao_mudar_sinal
  after update of status on app.appointment_deposits
  for each row when (new.status is distinct from old.status)
  execute function app.agenda_ao_mudar_sinal();

-- A fila passa a usar o titulo escolhido e uma descricao completa.
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
                 'titulo', app.agenda_titulo(a.id),
                 'inicio', a.starts_at,
                 'fim', a.ends_at,
                 'fuso', coalesce(u.timezone, 'America/Sao_Paulo'),
                 'descricao', concat_ws(E'\n',
                   coalesce(nullif(a.customer_label, ''), 'Cliente') || ' - ' || coalesce(s.nome, 'Atendimento'),
                   case when q.nomes is not null then 'Quem faz: ' || q.nomes end,
                   case when a.external_contact_ref is not null then 'WhatsApp: +' || a.external_contact_ref end,
                   case when vv.v ->> 'valorCentavos' is not null
                        then 'Valor: R$ ' || app.agenda_reais_curto((vv.v ->> 'valorCentavos')::integer) end,
                   case when vv.v ->> 'sinalPagoCentavos' is not null
                        then 'Sinal pago: R$ ' || app.agenda_reais_curto((vv.v ->> 'sinalPagoCentavos')::integer)
                             || ' (falta R$ ' || app.agenda_reais_curto(greatest((vv.v ->> 'valorCentavos')::integer
                                - (vv.v ->> 'sinalPagoCentavos')::integer, 0)) || ')' end,
                   'Marcado pela atendente do WhatsApp.')
               )) x
        from app.agenda_gravacoes g
        join app.appointments a on a.id = g.appointment_id
        join app.calendar_connections c on c.id = g.connection_id
        left join app.units u on u.id = a.unit_id
        cross join lateral (select app.agenda_valores_do_agendamento(a.id) v) vv
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

-- O cadastro que o Eddy le passa a mostrar o modo (e se falta perguntar).
create or replace function app.eddy_cadastro_resumido(p_tenant_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  with rascunho as (
    select d.id from app.configuration_drafts d
     where d.tenant_id = p_tenant_id
     order by d.revision desc limit 1
  )
  select jsonb_build_object(
    'servicos', coalesce((
      select jsonb_agg(
               s.name
               || coalesce(case when s.price_is_floor then ' a partir de R$' else ' R$' end || (s.base_price_minor / 100)::text, '')
               || coalesce(' [' || (
                    select string_agg(v.name || ' R$' || (v.price_minor / 100)::text, ', ' order by v.price_minor)
                      from app.service_variations v
                     where v.service_id = s.id and v.status = 'ACTIVE') || ']', '')
               || ': ' || coalesce((
                    select string_agg(
                             case when st.kind = 'PASSIVE'
                                  then 'pausa ' || st.duration_minutes || 'min '
                                       || case when st.releases_member then '(profissional LIVRE)'
                                               else '(profissional OCUPADA)' end
                                  else st.duration_minutes || 'min' end,
                             ' + ' order by st.position)
                      from app.service_steps st where st.service_id = s.id), 'sem etapas')
               || coalesce(' = total ' || (select sum(st.duration_minutes) from app.service_steps st where st.service_id = s.id) || 'min', '')
             order by s.name)
        from app.services s
       where s.tenant_id = p_tenant_id
         and s.configuration_draft_id = (select id from rascunho)
         and s.status = 'ACTIVE'), '[]'::jsonb),
    'equipe', coalesce((
      select jsonb_agg(
               m.name || ': ' ||
               case
                 when m.availability_mode::text = 'DYNAMIC' then
                   'SEM DIA FIXO (so atende nos dias que marca'
                   || coalesce('; marcados: ' || (
                        select string_agg(to_char(ds.shift_date, 'DD/MM') || ' ' || to_char(ds.starts_at, 'HH24:MI') || '-' || to_char(ds.ends_at, 'HH24:MI'), ', ' order by ds.shift_date)
                          from app.member_dynamic_shifts ds
                         where ds.member_id = m.id and ds.shift_date >= current_date), '; nenhum dia marcado daqui pra frente')
                   || ')'
                 else
                   coalesce((
                     select string_agg((array['dom','seg','ter','qua','qui','sex','sáb'])[a.weekday + 1] || ' ' || to_char(a.starts_at, 'HH24:MI') || '-' || to_char(a.ends_at, 'HH24:MI'), ', ' order by a.weekday)
                       from app.member_availability a where a.member_id = m.id), 'sem dias cadastrados')
                   || case when m.availability_mode::text = 'HYBRID' then ' (e dias extras marcados)' else '' end
               end
             order by m.name)
        from app.team_members m
       where m.tenant_id = p_tenant_id
         and m.configuration_draft_id = (select id from rascunho)
         and m.status = 'ACTIVE'), '[]'::jsonb),
    'horarios', coalesce((
      select jsonb_agg((array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])[h.weekday + 1] || ' ' || to_char(h.starts_at, 'HH24:MI') || '-' || to_char(h.ends_at, 'HH24:MI')
                       order by h.weekday)
        from app.operating_hours h
       where h.tenant_id = p_tenant_id
         and h.configuration_draft_id = (select id from rascunho)), '[]'::jsonb),
    'lembrete', (
      select case
               when a.lembrete_hora_local is null then 'desligado'
               else 'véspera às ' || a.lembrete_hora_local || 'h; texto atual: '
                    || coalesce('"' || a.lembrete_texto_desejado || '"', 'o modelo padrão')
                    || ' (para mudar, parta deste texto e mantenha tudo o que ele não pediu para tirar)'
             end
        from app.agent_scope a
       where a.tenant_id = p_tenant_id
       limit 1),
    'modoDaEquipe', (
      select case
               when (select count(*) from app.team_members m
                      where m.tenant_id = p_tenant_id and m.configuration_draft_id = (select id from rascunho)
                        and m.status = 'ACTIVE') < 2 then 'só uma pessoa na equipe (não precisa perguntar)'
               when a.equipe_como_um_so is null then 'AINDA NÃO PERGUNTADO: a cliente escolhe profissional ou é tudo com uma pessoa só?'
               when a.equipe_como_um_so then 'UM SÓ: a cliente sempre marca com ' || a.equipe_frente || ' (a equipe faz por ele/ela)'
               else 'SEPARADOS: cada profissional tem sua agenda e a cliente pode escolher'
             end
        from app.agent_scope a
       where a.tenant_id = p_tenant_id
       limit 1),
    'tituloNaAgenda', (
      select case
               when not exists (select 1 from app.calendar_connections c
                                 where c.tenant_id = p_tenant_id and c.provider = 'GOOGLE')
                 then 'agenda do Google não conectada (não precisa perguntar)'
               when a.agenda_titulo_modelo is null
                 then 'AINDA NÃO ESCOLHIDO (hoje sai: "' || app.agenda_aplicar_modelo(null, false,
                      '{"nome":"Carol","telefone":"16-99425-8547","servico":"Luzes","valorCentavos":45000}') || '")'
               else 'escolhido: ' || a.agenda_titulo_modelo
                    || case when a.agenda_titulo_caixa_alta then ' (tudo maiúsculo)' else '' end
                    || ' -> exemplo: "' || app.agenda_aplicar_modelo(a.agenda_titulo_modelo, a.agenda_titulo_caixa_alta,
                      '{"nome":"Carol","telefone":"16-99425-8547","servico":"Luzes","valorCentavos":45000,"sinalPagoCentavos":5000}') || '"'
             end
        from app.agent_scope a
       where a.tenant_id = p_tenant_id
       limit 1)
  );
$function$;

revoke all on function app.eddy_definir_modo_da_equipe(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.eddy_definir_modo_da_equipe(uuid, boolean, text) from public, anon, authenticated;
revoke all on function app.agente_modo_da_equipe(uuid) from public, anon, authenticated;
revoke all on function public.agente_modo_da_equipe(uuid) from public, anon, authenticated;
grant execute on function public.eddy_definir_modo_da_equipe(uuid, boolean, text) to service_role;
grant execute on function public.agente_modo_da_equipe(uuid) to service_role;

revoke all on function app.agenda_valores_do_agendamento(uuid) from public, anon, authenticated;
revoke all on function app.agenda_titulo(uuid) from public, anon, authenticated;
revoke all on function app.agenda_ao_mudar_sinal() from public, anon, authenticated;
revoke all on function app.eddy_definir_titulo_agenda(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.eddy_definir_titulo_agenda(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.eddy_definir_titulo_agenda(uuid, text, boolean) to service_role;