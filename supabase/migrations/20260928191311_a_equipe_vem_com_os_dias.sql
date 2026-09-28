-- A EQUIPE VEM COM OS DIAS DE CADA UM.
--
-- 28/09/2026, teste com dono-robo: "quem trabalha no sabado?" -> o Eddy disse
-- "todo mundo: Duda, Karen e William". A Duda nao tem dia fixo (so atende nos
-- dias que marca). O cadastro que o Eddy le trazia so os nomes da equipe; o
-- resto ele deduzia. Agora cada pessoa vem com o modo e os dias.

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
       limit 1)
  );
$function$;

revoke all on function app.eddy_cadastro_resumido(uuid) from public, anon, authenticated;
