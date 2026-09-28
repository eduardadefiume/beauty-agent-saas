-- O LEMBRETE ATUAL NA MESA DO EDDY.
--
-- 28/09/2026, teste com dono-robo: o lembrete tinha o aviso do interfone e o
-- "me confirma respondendo OK". O dono pediu "avisa TAMBEM do estacionamento"
-- e o Eddy reescreveu o texto de memoria: o estacionamento entrou, o interfone
-- e o pedido de confirmacao sumiram. O texto gravado nao estava no cadastro
-- que ele le a cada turno. Agora esta, e ele parte dele.

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
             order by s.name)
        from app.services s
       where s.tenant_id = p_tenant_id
         and s.configuration_draft_id = (select id from rascunho)
         and s.status = 'ACTIVE'), '[]'::jsonb),
    'equipe', coalesce((
      select jsonb_agg(m.name order by m.name)
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
