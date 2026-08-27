-- Duas correções que a importação real das 286 fichas do William revelou.
--
-- PROBLEMA 1 — A LINHA DA FILA MENTIA. Ela mostrava o procedimento que a
-- cliente mais faz e, ao lado, a cadência de OUTRO procedimento -- o primeiro
-- que por acaso tivesse uma. Em 41 das 287 fichas os dois eram diferentes, e a
-- linha lia-se como "Escova a cada 8 dias" quando o 8 vinha do cronograma
-- capilar dela. Número certo, frase falsa.
--
-- A correção separa os dois papéis em vez de fundi-los: `mainProcedure` é o que
-- ela mais faz, `cadenceProcedure` é o que dá o ritmo dela. Quando são o mesmo,
-- a tela mostra um só. Quando não são, mostra os dois -- que é a verdade.
-- `overdueDays` passa a usar a cadência do procedimento que a nomeia.
--
-- PROBLEMA 2 — CADÊNCIA DE DUAS VISITAS NÃO É CADÊNCIA. Duas visitas dão UM
-- intervalo. Um intervalo é uma observação, não um hábito: duas progressivas
-- com cinco dias de diferença quase sempre são um retoque ou uma correção, não
-- alguém que volta a cada cinco dias. Havia 66 linhas assim, uma delas
-- marcando "a cada 2 dias".
--
-- O dado não é apagado -- ele existe e pode ser útil. O que muda é a confiança:
-- abaixo de três visitas ela é BAIXA, sempre. Isso importa porque a confiança é
-- o que vai decidir se o agente pode chamar a cliente de volta sozinho. Chamar
-- alguém baseado num intervalo inventado é o tipo de erro que faz a dona
-- desligar o agente.

-- Estado atual.
update app.client_procedures
   set cadence_confidence = 'BAIXA'
 where times_done < 3 and cadence_confidence <> 'BAIXA';

-- E daqui pra frente, na importação: a regra vale no servidor, não na planilha
-- de quem exporta.
create or replace function app.cadence_confidence_for(p_times_done integer, p_declared text)
returns text
language sql
immutable
as $function$
  select case
    when coalesce(p_times_done, 0) < 3 then 'BAIXA'
    when p_declared in ('BAIXA', 'MEDIA', 'ALTA') then p_declared
    else 'BAIXA'
  end;
$function$;

comment on function app.cadence_confidence_for(integer, text) is
  'Duas visitas dao um intervalo, e um intervalo nao e um habito. Abaixo de tres visitas a confianca e BAIXA independente do que o arquivo declarar.';

-- A fila deixa de fundir dois procedimentos numa frase só. `mainProcedure` é o
-- que ela mais faz; `cadenceProcedure` é o que dá o ritmo dela. Quando são o
-- mesmo, a tela mostra um só. Quando não são, mostra os dois -- que é a verdade.
create or replace function public.site_load_clients(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_limit           integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_limite integer := least(greatest(coalesce(target_limit, 200), 1), 500);
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return jsonb_build_object(
    'clients', coalesce((
      select jsonb_agg(item order by
               (item->>'nextAppointmentAt') is null,
               item->>'nextAppointmentAt',
               (item->>'overdueDays')::integer desc nulls last,
               item->>'name')
        from (
          select jsonb_build_object(
                   'profileId', p.id,
                   'contactId', p.contact_id,
                   'name', coalesce(nullif(trim(p.preferred_name), ''), c.display_name, 'Sem nome'),
                   'phone', ch.address_normalized,
                   'status', p.status,
                   'pendencias', to_jsonb(app.client_profile_pendencias(p)),
                   'totalVisits', (select count(*) from app.client_visits v where v.profile_id = p.id),
                   'lastVisitOn', ultima.quando::text,
                   'mainProcedure', principal.label,
                   'cadenceProcedure', ritmo.label,
                   'cadenceDays', ritmo.cadence_days,
                   'cadenceConfidence', ritmo.cadence_confidence,
                   'overdueDays', case
                     when ritmo.cadence_days is not null and ultima.quando is not null
                       then (current_date - ultima.quando) - ritmo.cadence_days
                   end,
                   'nextAppointmentAt', (
                     select min(a.starts_at)::text
                       from app.appointments a
                      where a.tenant_id = p.tenant_id
                        and a.starts_at >= statement_timestamp()
                        and a.status <> 'CANCELLED'
                        and a.external_contact_ref is not null
                        and a.external_contact_ref = c.external_contact_ref
                   )
                 ) as item
            from app.client_profiles p
            join app.crm_contacts c on c.id = p.contact_id
            left join app.crm_contact_channels ch
              on ch.contact_id = c.id and ch.is_primary
            left join lateral (
              select max(v.occurred_on) as quando
                from app.client_visits v where v.profile_id = p.id
            ) ultima on true
            left join lateral (
              select pr.label from app.client_procedures pr
               where pr.profile_id = p.id
               order by pr.times_done desc, pr.label limit 1
            ) principal on true
            left join lateral (
              select pr.label, pr.cadence_days, pr.cadence_confidence
                from app.client_procedures pr
               where pr.profile_id = p.id and pr.cadence_days is not null
               order by pr.times_done desc, pr.label limit 1
            ) ritmo on true
           where p.tenant_id = target_tenant_id and p.status <> 'ARQUIVADA'
           limit v_limite
        ) pronto
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.site_load_clients(text, text, uuid, integer) from public, anon, authenticated;
grant execute on function public.site_load_clients(text, text, uuid, integer) to service_role;
