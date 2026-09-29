-- O EDDY MANDA O LINK DO GOOGLE AGENDA PELO WHATSAPP.
--
-- 29/09/2026. O convite (app.agenda_criar_convite) existia desde 26/09, mas
-- ninguem o criava: o aviso de "agenda caiu" mandava o dono responder
-- "conectar agenda" e o Eddy nao tinha ferramenta para isso.
--
-- Aqui: de QUEM e a agenda (profissional da equipe; sem nome, a do dono) e o
-- que ja esta conectado, para o Eddy nao mandar link de quem ja conectou sem
-- avisar. O link em si o codigo monta e manda num balao proprio: 32 letras
-- hexadecimais nao passam pelo modelo.
create or replace function app.eddy_conectar_agenda(p_tenant_id uuid, p_profissional text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
  v_equipe   text[];
  v_nome     text;
  v_dono     text;
  v_codigo   text;
  v_ja       jsonb;
begin
  select d.id into v_rascunho
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id
   order by d.updated_at desc
   limit 1;

  select coalesce(array_agg(tm.name order by tm.name), '{}') into v_equipe
    from app.team_members tm
   where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE';

  select tm.name into v_dono
    from app.team_members tm
    join app.owner_whatsapp o on o.tenant_id = tm.tenant_id and o.status = 'ACTIVE'
   where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'
     and app.agenda_nome_comparavel(tm.name) = app.agenda_nome_comparavel(o.display_name)
   limit 1;

  if nullif(trim(p_profissional), '') is null then
    v_nome := v_dono;
  else
    select tm.name into v_nome
      from app.team_members tm
     where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'
       and app.agenda_nome_comparavel(tm.name) = app.agenda_nome_comparavel(trim(p_profissional))
     limit 1;
    if v_nome is null then
      return jsonb_build_object('ok', false, 'reason', 'PROFISSIONAL_NAO_ESTA_NA_EQUIPE',
                                'procurado', trim(p_profissional), 'equipe', to_jsonb(v_equipe));
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'de', coalesce(c.member_name, 'salão todo'),
           'conta', c.external_account_email,
           'situacao', case when c.status = 'ACTIVE' then 'funcionando' else 'caiu, precisa conectar de novo' end,
           'ultimaLeitura', to_char(c.last_synced_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
         )), '[]'::jsonb)
    into v_ja
    from app.calendar_connections c
   where c.tenant_id = p_tenant_id and c.provider = 'GOOGLE';

  v_codigo := app.agenda_criar_convite(p_tenant_id, v_nome);

  return jsonb_build_object('ok', true, 'codigo', v_codigo, 'agendaDe', coalesce(v_nome, 'salão todo'),
                            'ehDoDono', v_nome is not distinct from v_dono,
                            'jaConectadas', v_ja, 'equipe', to_jsonb(v_equipe));
end;
$fn$;

create or replace function public.eddy_conectar_agenda(p_tenant_id uuid, p_profissional text default null)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_conectar_agenda(p_tenant_id, p_profissional); $$;

revoke all on function app.eddy_conectar_agenda(uuid, text) from public, anon, authenticated;
revoke all on function public.eddy_conectar_agenda(uuid, text) from public, anon, authenticated;
grant execute on function public.eddy_conectar_agenda(uuid, text) to service_role;
