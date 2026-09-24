-- O EDDY CONFIRMA LENDO O CADASTRO.
--
-- 24/09/2026, teste com dono-robo. O dono perguntou: "confere que nas mechas,
-- nos 45 minutos de pausa, a agenda NAO vai marcar outra cliente comigo?".
-- O Eddy respondeu "Confirmado. Fica travado mesmo." -- e no banco a pausa
-- estava com releases_member = true. Ele confirmou de memoria, porque nao
-- enxergava o cadastro gravado: so a lista do que falta.
--
-- eddy_cadastro_resumido devolve, do rascunho aberto, o que a atendente vai
-- usar: servicos com preco, variacoes e etapas (com a pausa e se ela libera a
-- profissional), equipe e horarios. Compacto de proposito: vai em todo turno.

create or replace function app.eddy_cadastro_resumido(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  with rascunho as (
    select d.id from app.configuration_drafts d
     where d.tenant_id = p_tenant_id
     order by d.revision desc limit 1
  )
  select jsonb_build_object(
    'servicos', coalesce((
      select jsonb_agg(
               s.name
               || coalesce(' R$' || (s.base_price_minor / 100)::text, '')
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
      select jsonb_agg(h.weekday || ' ' || to_char(h.starts_at, 'HH24:MI') || '-' || to_char(h.ends_at, 'HH24:MI')
                       order by h.weekday)
        from app.operating_hours h
       where h.tenant_id = p_tenant_id
         and h.configuration_draft_id = (select id from rascunho)), '[]'::jsonb)
  );
$fn$;

revoke all on function app.eddy_cadastro_resumido(uuid) from public, anon, authenticated;

create or replace function public.eddy_cadastro_resumido(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.eddy_cadastro_resumido(p_tenant_id); $$;

revoke all on function public.eddy_cadastro_resumido(uuid) from public, anon, authenticated;
grant execute on function public.eddy_cadastro_resumido(uuid) to service_role;

insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
select 'EDDY_CONFIRMAR_E_LER', 'Confirmar é ler',
$txt$CONFIRMAR É LER
Você recebe O CADASTRO COMO ESTÁ AGORA, lido do banco neste turno. É a única fonte para dizer "está certo", "confirmado", "já está assim".

Quando ele pedir para conferir alguma coisa, olhe lá. Se estiver como ele quer, diga que está e mostre o que está gravado. Se estiver diferente, NÃO confirme: corrija com a ferramenta certa e diga que corrigiu ("estava marcado como livre, corrigi: agora a agenda não encaixa ninguém nas mechas").

Nunca confirme de memória nem pelo que você disse antes na conversa. Você pode ter dito certo e gravado errado.$txt$,
59, 'ACTIVE', 'DONO'
where not exists (
  select 1 from app.agent_prompt_blocks where agent = 'DONO' and code = 'EDDY_CONFIRMAR_E_LER'
);
