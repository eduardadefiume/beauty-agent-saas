-- A ATENDENTE VE OS HORARIOS QUE A CLIENTE JA TEM.
--
-- 30/09/2026, DEV. A Bianca escreveu "vou ter que desmarcar o corte de
-- quarta" e a atendente respondeu "Ja cancelei aqui" -- sem ter cancelado
-- nada: ela nao enxergava os agendamentos da cliente e nao tinha ferramenta
-- de cancelar. O horario continuou CONFIRMADO, a cliente nao viria, e o
-- salao so descobriria com a cadeira vazia.
--
-- Aqui: os proximos horarios da cliente desta conversa (mesmo telefone,
-- mesmo salao), com o que e, quando e com quem. A atendente le isto a cada
-- turno e cancela pelo numero da lista.
create or replace function app.agente_agendamentos_da_cliente(p_conversation_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'appointmentId', a.id,
           'servico', coalesce(s.nome, 'Atendimento'),
           'quando', to_char(a.starts_at at time zone coalesce(u.timezone, 'America/Sao_Paulo'), 'DD/MM HH24:MI'),
           'diaDaSemana', (array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])[
                             extract(dow from a.starts_at at time zone coalesce(u.timezone, 'America/Sao_Paulo'))::int + 1],
           'com', q.nomes,
           'situacao', case a.status when 'CONFIRMED' then 'confirmado'
                                     when 'PENDING_SIGNAL' then 'aguardando sinal' end,
           'horasAte', floor(extract(epoch from (a.starts_at - statement_timestamp())) / 3600)
         ) order by a.starts_at), '[]'::jsonb)
    from app.crm_conversations c
    join app.appointments a
      on a.tenant_id = c.tenant_id
     and right(regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
       = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 11)
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
   where c.id = p_conversation_id
     and length(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g')) >= 8
     and a.starts_at > statement_timestamp()
     and a.status in ('CONFIRMED', 'PENDING_SIGNAL');
$fn$;

create or replace function public.agente_agendamentos_da_cliente(p_conversation_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.agente_agendamentos_da_cliente(p_conversation_id); $$;

revoke all on function app.agente_agendamentos_da_cliente(uuid) from public, anon, authenticated;
revoke all on function public.agente_agendamentos_da_cliente(uuid) from public, anon, authenticated;
grant execute on function public.agente_agendamentos_da_cliente(uuid) to service_role;
