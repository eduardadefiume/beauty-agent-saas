-- O princípio da polaridade aplicado à fila: escala, não etiqueta.
--
-- `overdueDays` conta dias absolutos, e dias absolutos comparam clientes que
-- não são comparáveis. Trinta dias de atraso num cronograma capilar de 7 dias
-- é abandono; trinta dias numa cliente de luzes de 161 dias é rotina. Ordenar
-- as duas pela mesma régua põe a segunda na frente da primeira.
--
-- `cycleRatio` é dias sem vir dividido pela cadência DELA. 1.0 é o ponto
-- exato do ciclo, 0.8 é a hora de chamar, acima de 1 é atraso. É a mesma
-- medida para a cliente semanal e para a de cinco em cinco meses.
--
-- Sobre o mínimo de ocorrências: o framework exige duas para inferir ritmo, e
-- é isso que existe -- só há cadência onde houve pelo menos duas visitas. A
-- regra de confiança BAIXA abaixo de três visitas não contradiz isso: ela não
-- apaga a cadência, gradua. Duas visitas dão um ritmo possível; três dão um
-- ritmo em que se pode agir sozinho. A fila mostra as duas coisas e deixa a
-- decisão de agir para quem lê.
--
-- Os dois campos convivem de propósito. `overdueDays` é o que a dona lê
-- ("está há 96 dias sem vir"); `cycleRatio` é o que ordena.

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
               -- A fila da tela é trabalho de cadastro: quem chega primeiro
               -- precisa de ficha primeiro.
               (item->>'nextAppointmentAt') is null,
               item->>'nextAppointmentAt',
               -- Sem horário marcado, quem está mais longe do próprio ritmo.
               (item->>'cycleRatio')::numeric desc nulls last,
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
                   'daysSinceLastVisit', case
                     when ultima.quando is not null then current_date - ultima.quando end,
                   'mainProcedure', principal.label,
                   'cadenceProcedure', ritmo.label,
                   'cadenceDays', ritmo.cadence_days,
                   'cadenceConfidence', ritmo.cadence_confidence,
                   -- Dias além do ciclo. É o número que a dona lê.
                   'overdueDays', case
                     when ritmo.cadence_days is not null and ultima.quando is not null
                       then (current_date - ultima.quando) - ritmo.cadence_days
                   end,
                   -- Onde ela está no próprio ciclo. É o número que ordena.
                   'cycleRatio', case
                     when ritmo.cadence_days is not null and ultima.quando is not null
                       then round((current_date - ultima.quando)::numeric / ritmo.cadence_days, 2)
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
