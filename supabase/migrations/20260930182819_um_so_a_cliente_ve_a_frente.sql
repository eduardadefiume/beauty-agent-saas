-- UM SÓ: A CLIENTE VÊ A FRENTE.
--
-- 30/09, DEV (salão do William, equipe como um só, frente William): a Paula
-- marcou ouvindo "com William" e, ao perguntar "que horas ficou mesmo?",
-- ouviu "com a Karen" -- quem faz de verdade. Para a cliente, no modo um só,
-- o salão é o William. Quem faz de verdade vai à parte, para quando ela
-- mesma pediu aquela profissional.
create or replace function app.agente_agendamentos_da_cliente(p_conversation_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'appointmentId', a.id,
           'servico', coalesce(s.nome, 'Atendimento'),
           'quando', to_char(a.starts_at at time zone coalesce(u.timezone, 'America/Sao_Paulo'), 'DD/MM HH24:MI'),
           'diaDaSemana', (array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])[
                             extract(dow from a.starts_at at time zone coalesce(u.timezone, 'America/Sao_Paulo'))::int + 1],
           'com', case when coalesce(sc.equipe_como_um_so, false) and sc.equipe_frente is not null
                       then sc.equipe_frente else q.nomes end,
           'quemFazDeVerdade', case when coalesce(sc.equipe_como_um_so, false) then q.nomes end,
           'situacao', case a.status when 'CONFIRMED' then 'confirmado'
                                     when 'PENDING_SIGNAL' then 'aguardando sinal' end,
           'horasAte', floor(extract(epoch from (a.starts_at - statement_timestamp())) / 3600)
         ) order by a.starts_at), '[]'::jsonb)
    from app.crm_conversations c
    join app.appointments a
      on a.tenant_id = c.tenant_id
     and right(regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
       = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 11)
    left join lateral (
      select x.equipe_como_um_so, x.equipe_frente
        from app.agent_scope x
       where x.tenant_id = c.tenant_id
       limit 1) sc on true
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
$function$;

revoke all on function app.agente_agendamentos_da_cliente(uuid) from public, anon, authenticated;