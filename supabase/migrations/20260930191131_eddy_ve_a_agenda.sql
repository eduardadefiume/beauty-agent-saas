-- O EDDY VÊ A AGENDA.
--
-- 30/09, DEV: o dono perguntou "quantas clientes marcaram essa semana?" e o
-- Eddy respondeu "não tenho acesso a relatório de agenda". A Duda: "o William
-- vai perguntar isso no primeiro dia".
--
-- Duas perguntas diferentes que o dono faz com as mesmas palavras:
--   * quem VEM no período (atendimentos com início dentro dele);
--   * quantas MARCARAM no período (agendamentos criados dentro dele).
-- Devolve as duas e o Eddy responde a que ele perguntou. Só o que passou pelo
-- sistema: compromisso que o dono pôs direto no Google não é cliente aqui.
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
                             then 'R$ ' || ((val ->> 'valorCentavos')::int / 100) end,
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

revoke all on function app.eddy_ver_agenda(uuid, date, date) from public, anon, authenticated;