-- DESCRIÇÃO DO GOOGLE TAMBÉM DIZ "A PARTIR DE".
-- 01/10, DEV: depois do sinal confirmado, o evento da Marina saiu com título
-- certo ("A PARTIR DE 420 DEU 100") e descrição errada: "Valor: R$ 420 /
-- Sinal pago: R$ 100 (falta R$ 320)". Com preço mínimo, o resto só se sabe
-- no dia: "falta" vira "o resto no dia". Mesmo erro de 20261001171135, num
-- lugar que aquela migração não cobriu.
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
                        then 'Valor: ' || case when coalesce((vv.v ->> 'valorAPartirDe')::boolean, false)
                                               then 'a partir de ' else '' end
                             || 'R$ ' || app.agenda_reais_curto((vv.v ->> 'valorCentavos')::integer) end,
                   case when vv.v ->> 'sinalPagoCentavos' is not null
                        then 'Sinal pago: R$ ' || app.agenda_reais_curto((vv.v ->> 'sinalPagoCentavos')::integer)
                             || case when coalesce((vv.v ->> 'valorAPartirDe')::boolean, false)
                                     then ' (o resto no dia)'
                                     else ' (falta R$ ' || app.agenda_reais_curto(greatest((vv.v ->> 'valorCentavos')::integer
                                          - (vv.v ->> 'sinalPagoCentavos')::integer, 0)) || ')' end end,
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

-- Regrava no Google os eventos futuros de serviço "a partir de" com sinal pago.
select app.agenda_enfileirar(a.id)
  from app.appointments a
 where a.status = 'CONFIRMED' and a.starts_at > statement_timestamp()
   and coalesce((app.agenda_valores_do_agendamento(a.id) ->> 'valorAPartirDe')::boolean, false)
   and exists (select 1 from app.appointment_deposits d where d.appointment_id = a.id and d.status = 'CONFIRMED');
