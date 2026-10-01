-- "A PARTIR DE" EM TODO LUGAR QUE MOSTRA VALOR.
-- 01/10, DEV: o cartão do sinal da Marina disse "Valor: R$ 420" para Luzes, que
-- no cadastro é "a partir de R$ 420". A cliente lê como preço fechado e briga
-- no dia. O mesmo valor sai no título do Google ("420 DEU 100 FICOU 320": o
-- "ficou" é chute), na agenda que o Eddy mostra ao dono e no rótulo antigo.
-- Regra: preço mínimo é sempre dito como mínimo; "ficou X" só com preço fechado.

create or replace function app.agenda_valores_do_agendamento(p_appointment_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'nome', coalesce(split_part(nullif(trim(a.customer_label), ''), ' ', 1), 'Cliente'),
    'telefone', case
      when length(d.dig) >= 12 and left(d.dig, 2) = '55'
        then substr(d.dig, 3, 2) || '-' || substr(d.dig, 5, length(d.dig) - 8) || '-' || right(d.dig, 4)
      when length(d.dig) >= 10
        then substr(d.dig, 1, 2) || '-' || substr(d.dig, 3, length(d.dig) - 6) || '-' || right(d.dig, 4)
      else coalesce(nullif(d.dig, ''), '') end,
    'servico', coalesce(s.nome, 'Atendimento'),
    'valorCentavos', p.preco,
    'valorAPartirDe', p.minimo,
    'sinalPagoCentavos', (select dp.amount_cents from app.appointment_deposits dp
                           where dp.appointment_id = a.id and dp.status = 'CONFIRMED' limit 1),
    'profissional', case when coalesce(sc.equipe_como_um_so, false)
                              and not coalesce(sc.agenda_mostra_quem_faz, true)
                              and sc.equipe_frente is not null
                         then sc.equipe_frente else q.nomes end,
    'profissionalReal', q.nomes)
  from app.appointments a
  cross join lateral (select regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g') dig) d
  left join lateral (
    select x.equipe_como_um_so, x.equipe_frente, x.agenda_mostra_quem_faz
      from app.agent_scope x where x.tenant_id = a.tenant_id limit 1) sc on true
  left join lateral (
    select sv ->> 'name' nome, sv
      from app.configuration_versions v
      cross join lateral jsonb_array_elements(coalesce(v.snapshot -> 'services', '[]'::jsonb)) sv
     where v.id = a.configuration_version_id and sv ->> 'id' = a.service_id::text
     limit 1) s on true
  left join lateral (
    select case when a.variation_id is null then null else (
             select va from jsonb_array_elements(coalesce(s.sv -> 'variations', '[]'::jsonb)) va
              where va ->> 'id' = a.variation_id::text limit 1) end va) vr on true
  left join lateral (
    select coalesce((vr.va ->> 'price_minor')::integer, (s.sv ->> 'base_price_minor')::integer) preco,
           coalesce((vr.va ->> 'price_is_floor')::boolean, (s.sv ->> 'price_is_floor')::boolean, false) minimo) p on true
  left join lateral (
    select string_agg(distinct tm.name, ' e ') nomes
      from jsonb_array_elements(coalesce(a.plan -> 'steps', '[]'::jsonb)) passo
      join app.team_members tm on tm.id::text = passo ->> 'memberId') q on true
  where a.id = p_appointment_id;
$function$;

create or replace function app.agenda_aplicar_modelo(p_modelo text, p_caixa_alta boolean, p_v jsonb)
 returns text
 language plpgsql
 immutable
 set search_path to ''
as $function$
declare
  v_vazio  constant text := chr(1);
  v_minimo boolean := coalesce((p_v ->> 'valorAPartirDe')::boolean, false);
  v_valor  text := app.agenda_reais_curto((p_v ->> 'valorCentavos')::integer);
  v_sinal  integer := (p_v ->> 'sinalPagoCentavos')::integer;
  v_pag    text;
  v_t      text;
begin
  if v_minimo and v_valor is not null then
    v_valor := 'a partir de ' || v_valor;
  end if;
  v_pag := case
    when v_valor is null then null
    -- Preço mínimo: o resto só se sabe no dia. Diz quanto deu, não quanto "ficou".
    when v_minimo and v_sinal is not null and v_sinal > 0 then
      v_valor || ' DEU ' || app.agenda_reais_curto(v_sinal)
    when v_sinal is not null and v_sinal >= (p_v ->> 'valorCentavos')::integer then v_valor || ' PAGO'
    when v_sinal is not null and v_sinal > 0 then
      v_valor || ' DEU ' || app.agenda_reais_curto(v_sinal) || ' FICOU '
      || app.agenda_reais_curto(greatest((p_v ->> 'valorCentavos')::integer - v_sinal, 0))
    else v_valor end;
  v_t := coalesce(nullif(trim(p_modelo), ''), '{nome} {telefone} - {servico}');
  v_t := replace(v_t, '{nome}', coalesce(nullif(p_v ->> 'nome', ''), v_vazio));
  v_t := replace(v_t, '{telefone}', coalesce(nullif(p_v ->> 'telefone', ''), v_vazio));
  v_t := replace(v_t, '{servico}', coalesce(nullif(p_v ->> 'servico', ''), v_vazio));
  v_t := replace(v_t, '{valor}', coalesce(v_valor, v_vazio));
  v_t := replace(v_t, '{pagamento}', coalesce(v_pag, v_vazio));
  v_t := replace(v_t, '{profissional}', coalesce(nullif(p_v ->> 'profissional', ''), v_vazio));
  v_t := regexp_replace(v_t, '\([^()]*' || v_vazio || '[^()]*\)', '', 'g');
  v_t := regexp_replace(v_t, 'R\$\s*' || v_vazio, '', 'g');
  -- "R$ a partir de 420" (modelo do dono com "R$ {valor}") vira "a partir de R$ 420".
  v_t := regexp_replace(v_t, 'R\$\s*a partir de\s+', 'a partir de R$ ', 'g');
  v_t := replace(v_t, v_vazio, '');
  v_t := regexp_replace(v_t, '\s{2,}', ' ', 'g');
  v_t := regexp_replace(v_t, '(\s*-\s*){2,}', ' - ', 'g');
  v_t := regexp_replace(v_t, '^\s*-\s*|\s*-\s*$', '', 'g');
  v_t := trim(v_t);
  return case when p_caixa_alta then upper(v_t) else v_t end;
end;
$function$;

create or replace function app.sinal_cartao(p_appointment_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  a app.appointments%rowtype;
  d app.appointment_deposits%rowtype;
  c app.sinal_config%rowtype;
  v jsonb;
  v_tz text;
  v_ini timestamp;
  v_prazo timestamp;
  v_dias text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_minimo boolean;
  v_texto text;
begin
  select * into a from app.appointments where id = p_appointment_id;
  select * into d from app.appointment_deposits where appointment_id = p_appointment_id;
  if a.id is null or d.id is null or d.status <> 'PENDING' or a.status <> 'PENDING_SIGNAL' then
    return jsonb_build_object('comSinal', false);
  end if;
  select * into c from app.sinal_config where tenant_id = a.tenant_id;
  v := app.agenda_valores_do_agendamento(a.id);
  v_minimo := coalesce((v ->> 'valorAPartirDe')::boolean, false);
  select coalesce(u.timezone, 'America/Sao_Paulo') into v_tz from app.units u where u.id = a.unit_id;
  v_tz := coalesce(v_tz, 'America/Sao_Paulo');
  v_ini := a.starts_at at time zone v_tz;
  v_prazo := d.due_at at time zone v_tz;

  v_texto :=
    '📌 *Seu horário está reservado!*' || E'\n' ||
    (v ->> 'servico') || ' — ' || v_dias[extract(dow from v_ini)::int + 1] || ', ' ||
      to_char(v_ini, 'DD/MM') || ' às ' || to_char(v_ini, 'HH24"h"MI') ||
      coalesce(', com ' || (v ->> 'profissional'), '') || E'\n' ||
    case when v ->> 'valorCentavos' is not null
         then 'Valor: ' || case when v_minimo then 'a partir de ' else '' end
              || 'R$ ' || app.agenda_reais_curto((v ->> 'valorCentavos')::int) || ' | '
         else '' end ||
    'Sinal: *R$ ' || app.agenda_reais_curto(d.amount_cents) || '*' ||
    case when v ->> 'valorCentavos' is not null then ' (já descontado do valor)' else '' end || E'\n\n' ||
    'Para confirmar, faça o Pix do sinal até *' || v_dias[extract(dow from v_prazo)::int + 1] || ', ' ||
      to_char(v_prazo, 'DD/MM') || ' às ' || to_char(v_prazo, 'HH24"h"MI') || '*:' || E'\n' ||
    'Chave Pix: ' || coalesce(c.pix_chave, '(o salão te passa)') || E'\n' ||
    coalesce('Nome: ' || c.pix_titular || E'\n', '') ||
    'Depois é só me mandar o comprovante aqui. 💛' || E'\n\n' ||
    'O sinal garante o seu horário. Se não for pago até o prazo, ele é liberado para outra cliente.' ||
    case when c.reembolso_respondido and c.reembolso_ate_horas is not null
           then ' Se precisar desmarcar com pelo menos ' || c.reembolso_ate_horas || 'h de antecedência, o sinal é devolvido.'
         when c.reembolso_respondido
           then ' Se precisar desmarcar, o sinal não é devolvido.'
         else '' end;

  return jsonb_build_object('comSinal', true, 'texto', v_texto,
    'valorCentavos', d.amount_cents, 'prazo', d.due_at);
end;
$function$;

create or replace function app.eddy_ver_agenda(p_tenant_id uuid, p_de date, p_ate date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_tz text;
  v_ini timestamptz;
  v_fim timestamptz;
begin
  if p_de is null or p_ate is null or p_ate < p_de then
    return jsonb_build_object('ok', false, 'reason', 'PERIODO_INVALIDO');
  end if;
  if p_ate - p_de > 62 then
    return jsonb_build_object('ok', false, 'reason', 'PERIODO_GRANDE_DEMAIS');
  end if;

  select coalesce(u.timezone, 'America/Sao_Paulo') into v_tz
    from app.units u where u.tenant_id = p_tenant_id order by u.created_at limit 1;
  v_tz := coalesce(v_tz, 'America/Sao_Paulo');
  v_ini := p_de::timestamp at time zone v_tz;
  v_fim := (p_ate + 1)::timestamp at time zone v_tz;

  return jsonb_build_object(
    'ok', true,
    'de', to_char(p_de, 'DD/MM'),
    'ate', to_char(p_ate, 'DD/MM'),
    'atendimentos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia', (array['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow from a.starts_at at time zone v_tz)::int + 1]
                      || ' ' || to_char(a.starts_at at time zone v_tz, 'DD/MM'),
               'hora', to_char(a.starts_at at time zone v_tz, 'HH24:MI'),
               'cliente', val ->> 'nome',
               'telefone', val ->> 'telefone',
               'servico', val ->> 'servico',
               'com', val ->> 'profissional',
               'valor', case when val ->> 'valorCentavos' is not null
                             then case when coalesce((val ->> 'valorAPartirDe')::boolean, false)
                                       then 'a partir de ' else '' end
                                  || 'R$ ' || ((val ->> 'valorCentavos')::int / 100) end,
               'situacao', case a.status when 'CONFIRMED' then 'confirmado'
                                         when 'PENDING_SIGNAL' then 'esperando o sinal' end)
             order by a.starts_at)
        from app.appointments a
        cross join lateral (select app.agenda_valores_do_agendamento(a.id) val) v
       where a.tenant_id = p_tenant_id
         and a.starts_at >= v_ini and a.starts_at < v_fim
         and a.status in ('CONFIRMED', 'PENDING_SIGNAL')), '[]'::jsonb),
    'totalAtendimentos', (
      select count(*) from app.appointments a
       where a.tenant_id = p_tenant_id and a.starts_at >= v_ini and a.starts_at < v_fim
         and a.status in ('CONFIRMED', 'PENDING_SIGNAL')),
    'esperandoSinal', (
      select count(*) from app.appointments a
       where a.tenant_id = p_tenant_id and a.starts_at >= v_ini and a.starts_at < v_fim
         and a.status = 'PENDING_SIGNAL'),
    'valorPrevistoReais', (
      select coalesce(sum((app.agenda_valores_do_agendamento(a.id) ->> 'valorCentavos')::int), 0) / 100
        from app.appointments a
       where a.tenant_id = p_tenant_id and a.starts_at >= v_ini and a.starts_at < v_fim
         and a.status in ('CONFIRMED', 'PENDING_SIGNAL')),
    -- true: algum serviço do período é "a partir de", então o previsto é o MÍNIMO.
    'valorPrevistoEMinimo', coalesce((
      select bool_or(coalesce((app.agenda_valores_do_agendamento(a.id) ->> 'valorAPartirDe')::boolean, false))
        from app.appointments a
       where a.tenant_id = p_tenant_id and a.starts_at >= v_ini and a.starts_at < v_fim
         and a.status in ('CONFIRMED', 'PENDING_SIGNAL')), false),
    'desmarcadosNoPeriodo', (
      select count(*) from app.appointments a
       where a.tenant_id = p_tenant_id and a.starts_at >= v_ini and a.starts_at < v_fim
         and a.status = 'CANCELLED'),
    'marcacoesFeitasNoPeriodo', (
      select count(*) from app.appointments a
       where a.tenant_id = p_tenant_id and a.created_at >= v_ini and a.created_at < v_fim
         and a.status in ('CONFIRMED', 'PENDING_SIGNAL'))
  );
end;
$function$;

create or replace function app.appointment_label(p_appointment_id uuid)
 returns text
 language sql
 stable security definer
 set search_path to ''
as $function$
  with a as (
    select ap.*, s.name as servico, s.base_price_minor, coalesce(s.price_is_floor, false) as minimo
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
           (select centavos from pago)             as ja_pago,
           (select minimo from a)                  as minimo
  )
  select
    coalesce(nullif(trim((select customer_label from a)), ''), 'sem nome')
    || coalesce(' (' || app.telefone_legivel((select digitos from contato)) || ')', '')
    || coalesce(' - ' || (select servico from a), '')
    || case
         when (select preco from dinheiro) is null then ''
         when (select minimo from dinheiro) and (select ja_pago from dinheiro) = 0 then
           ' (a partir de ' || app.reais_curtos((select preco from dinheiro)) || ')'
         when (select minimo from dinheiro) then
           ' (a partir de ' || app.reais_curtos((select preco from dinheiro))
           || ' deu ' || app.reais_curtos((select ja_pago from dinheiro)) || ')'
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
