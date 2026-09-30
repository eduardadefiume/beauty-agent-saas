-- A DESCRIÇÃO DO EVENTO SEGUE A MESMA ESCOLHA DO TÍTULO.
--
-- 30/09: o William pediu "tudo no meu nome" no Google; o título virou
-- "... - WILLIAM", mas a descrição continuou "Quem faz: Karen" porque lia o
-- nome direto do plano. Agora os dois leem agenda_valores_do_agendamento.
create or replace function app.agenda_gravacoes_pendentes(p_limite integer default 20)
 returns jsonb
 language sql
 security definer
 set search_path to ''
as $function$
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
                   case when vv.v ->> 'profissional' is not null then 'Quem faz: ' || (vv.v ->> 'profissional') end,
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
       where g.pendente
         and g.tentativas < 8
         and c.status = 'ACTIVE'
         and c.refresh_token is not null
       order by g.atualizado_em
       limit greatest(coalesce(p_limite, 20), 1)
    ) t;
$function$;

-- Os eventos já reescritos com a descrição antiga voltam para a fila.
select app.agenda_enfileirar(a.id)
  from app.appointments a
  join app.agent_scope s on s.tenant_id = a.tenant_id
 where s.equipe_como_um_so and not s.agenda_mostra_quem_faz
   and a.ends_at > statement_timestamp()
   and a.status in ('CONFIRMED', 'COMPLETED');