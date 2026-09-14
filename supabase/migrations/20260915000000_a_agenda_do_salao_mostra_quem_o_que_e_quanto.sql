-- A AGENDA DO SALAO MOSTRA QUEM, O QUE E QUANTO.
--
-- A proprietaria abriu o site depois de o agente marcar sexta 18/09 as 13h e
-- nao viu o atendimento. Nao era bug de reserva: o agendamento existe,
-- CONFIRMED, com o servico certo. A tela que ela abriu e a do GOOGLE -- esta
-- escrito no proprio codigo dela: "nao e a agenda de atendimentos, e o que veio
-- de fora bloqueando horario". A agenda do salao nunca teve tela.
--
-- E quando fui montar a tela, faltava dado. O agendamento guardava a string
-- "Eduarda" e mais nada: nem telefone, nem de qual conversa veio. As duas
-- colunas existem na tabela desde o inicio (`external_contact_ref` e
-- `channel_connection_id`) e chegavam como `null` fixo, escrito na
-- scheduling-api. Nome solto nao identifica ninguem num salao com duas Marias.
-- O conserto da origem esta na scheduling-api e no whatsapp-agent, no mesmo
-- commit.
--
-- O FORMATO E DA PROPRIETARIA, com as palavras dela:
--
--   Eduarda (16-99421-5487) - Morena Iluminada (420)
--   Eduarda (16-99421-5487) - Morena Iluminada (420 deu 100 - falta 320)
--
-- O rotulo e CALCULADO, nunca gravado. Sinal muda: a cliente paga 100 hoje e o
-- resto na cadeira. String congelada no momento da reserva mentiria no dia
-- seguinte -- e a agenda e justamente onde quem atende confere quanto falta
-- receber.
--
-- O telefone sai do jeito que se le no Brasil: sem o 55, com o DDD separado.
-- Quem esta com o celular na mao para ligar nao quer decorar 13 digitos
-- colados.

create or replace function app.telefone_legivel(p_digitos text)
returns text
language sql
immutable
set search_path to ''
as $function$
  with d as (
    select regexp_replace(coalesce(p_digitos, ''), '[^0-9]', '', 'g') as n
  ),
  sem_pais as (
    select case when length(n) in (12, 13) and left(n, 2) = '55' then substr(n, 3) else n end as n
      from d
  )
  select case
           when length(n) = 11 then substr(n,1,2) || '-' || substr(n,3,5) || '-' || substr(n,8,4)
           when length(n) = 10 then substr(n,1,2) || '-' || substr(n,3,4) || '-' || substr(n,7,4)
           when n = '' then null
           else n
         end
    from sem_pais;
$function$;

revoke all on function app.telefone_legivel(text) from public, anon, authenticated;
grant execute on function app.telefone_legivel(text) to service_role;

create or replace function app.reais_curtos(p_centavos bigint)
returns text
language sql
immutable
set search_path to ''
as $function$
  select case
           when p_centavos is null then null
           when p_centavos % 100 = 0 then (p_centavos / 100)::text
           else replace(to_char(p_centavos / 100.0, 'FM999999990.00'), '.', ',')
         end;
$function$;

revoke all on function app.reais_curtos(bigint) from public, anon, authenticated;
grant execute on function app.reais_curtos(bigint) to service_role;

create or replace function app.appointment_label(p_appointment_id uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  with a as (
    select ap.*, s.name as servico, s.base_price_minor
      from app.appointments ap
      left join app.services s on s.id = ap.service_id
     where ap.id = p_appointment_id
  ),
  contato as (
    select coalesce(
             nullif(trim((select external_contact_ref from a)), ''),
             (select ch.address_normalized
                from app.crm_contact_channels ch
                join app.crm_contacts ct on ct.id = ch.contact_id
               where ct.tenant_id = (select tenant_id from a)
                 and ch.provider = 'WHATSAPP'
                 and lower(coalesce(ct.display_name, '')) = lower(coalesce((select customer_label from a), ''))
               limit 1)
           ) as digitos
  ),
  pago as (
    select coalesce(sum(d.amount_cents), 0)::bigint as centavos
      from app.appointment_deposits d
     where d.appointment_id = p_appointment_id
       and d.status = 'CONFIRMED'
  ),
  dinheiro as (
    select (select base_price_minor from a)::bigint as preco,
           (select centavos from pago)             as ja_pago
  )
  select
    coalesce(nullif(trim((select customer_label from a)), ''), 'sem nome')
    || coalesce(' (' || app.telefone_legivel((select digitos from contato)) || ')', '')
    || coalesce(' - ' || (select servico from a), '')
    || case
         when (select preco from dinheiro) is null then ''
         when (select ja_pago from dinheiro) = 0 then
           ' (' || app.reais_curtos((select preco from dinheiro)) || ')'
         when (select ja_pago from dinheiro) >= (select preco from dinheiro) then
           ' (' || app.reais_curtos((select preco from dinheiro)) || ' pago)'
         else
           ' (' || app.reais_curtos((select preco from dinheiro))
           || ' deu ' || app.reais_curtos((select ja_pago from dinheiro))
           || ' - falta ' || app.reais_curtos((select preco from dinheiro) - (select ja_pago from dinheiro))
           || ')'
       end;
$function$;

revoke all on function app.appointment_label(uuid) from public, anon, authenticated;
grant execute on function app.appointment_label(uuid) to service_role;

create or replace function app.agenda_do_salao(
  p_tenant_id uuid,
  p_de timestamptz,
  p_ate timestamptz
)
returns table(
  appointment_id uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  status text,
  rotulo text,
  servico text,
  telefone text
)
language sql
stable
security definer
set search_path to ''
as $function$
  select ap.id, ap.starts_at, ap.ends_at, ap.status::text,
         app.appointment_label(ap.id),
         s.name,
         app.telefone_legivel(ap.external_contact_ref)
    from app.appointments ap
    left join app.services s on s.id = ap.service_id
   where ap.tenant_id = p_tenant_id
     and ap.starts_at >= p_de
     and ap.starts_at < p_ate
     and ap.status <> 'CANCELLED'
   order by ap.starts_at;
$function$;

revoke all on function app.agenda_do_salao(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function app.agenda_do_salao(uuid, timestamptz, timestamptz) to service_role;

create or replace function public.site_agenda_do_salao(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_de timestamptz,
  target_ate timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_lista jsonb;
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'appointmentId', a.appointment_id,
           'inicio',        a.starts_at,
           'fim',           a.ends_at,
           'status',        a.status,
           'rotulo',        a.rotulo,
           'servico',       a.servico,
           'telefone',      a.telefone
         ) order by a.starts_at), '[]'::jsonb)
    into v_lista
    from app.agenda_do_salao(target_tenant_id, target_de, target_ate) a;

  return jsonb_build_object('ok', true, 'atendimentos', v_lista);
end;
$function$;

revoke all on function public.site_agenda_do_salao(text, text, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.site_agenda_do_salao(text, text, uuid, timestamptz, timestamptz)
  to service_role;
