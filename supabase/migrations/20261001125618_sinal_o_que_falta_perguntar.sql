-- SINAL: O EDDY SABE O QUE AINDA FALTA PERGUNTAR AO DONO.
--
-- Uma pergunta por vez, nesta ordem: valores por procedimento, período,
-- prazo para pagar, Pix, devolução; e por último ligar. Período e prazo
-- têm resposta padrão ("sempre", "24h"), por isso precisam de marca de
-- respondido: sem ela o Eddy não sabe se o dono escolheu o padrão ou se
-- ninguém perguntou.
alter table app.sinal_config
  add column if not exists periodo_respondido boolean not null default false,
  add column if not exists prazo_respondido boolean not null default false;

create or replace function app.sinal_resumo(p_tenant_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'ativo', coalesce(c.ativo, false),
    'valores', coalesce((select jsonb_object_agg(v.servico_nome, 'R$ ' || app.agenda_reais_curto(v.valor_centavos))
                           from app.sinal_valores v where v.tenant_id = p_tenant_id), '{}'::jsonb),
    'periodo', case when c.vale_de is null and c.vale_ate is null then 'sempre'
                    else coalesce(to_char(c.vale_de, 'DD/MM/YYYY'), 'hoje') || ' a '
                      || coalesce(to_char(c.vale_ate, 'DD/MM/YYYY'), 'sem fim') end,
    'prazoHoras', coalesce(c.prazo_horas, 24),
    'prazoQuandoMarcaNoMesAnteriorHoras', c.prazo_mes_anterior_horas,
    'pagarAteAntesDoHorarioMin', coalesce(c.pagar_ate_antes_min, 120),
    'pix', case when c.pix_chave is null then null else c.pix_chave || coalesce(' (' || c.pix_titular || ')', '') end,
    'devolveQuandoDesmarca', case when not coalesce(c.reembolso_respondido, false) then 'AINDA NÃO PERGUNTADO'
                                  when c.reembolso_ate_horas is null then 'não devolve'
                                  else 'devolve se avisar com ' || c.reembolso_ate_horas || 'h de antecedência' end,
    'falta', to_jsonb(array_remove(array[
      case when not exists (select 1 from app.sinal_valores v where v.tenant_id = p_tenant_id) then 'VALORES' end,
      case when not coalesce(c.periodo_respondido, false) then 'PERIODO' end,
      case when not coalesce(c.prazo_respondido, false) then 'PRAZO' end,
      case when c.pix_chave is null then 'PIX' end,
      case when not coalesce(c.reembolso_respondido, false) then 'DEVOLUCAO' end,
      case when not coalesce(c.ativo, false) then 'LIGAR' end
    ], null)))
  from (select 1) um
  left join app.sinal_config c on c.tenant_id = p_tenant_id;
$function$;

create or replace function app.eddy_definir_sinal(p_tenant_id uuid, p_campos jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c app.sinal_config%rowtype;
begin
  insert into app.sinal_config (tenant_id) values (p_tenant_id) on conflict (tenant_id) do nothing;
  select * into c from app.sinal_config where tenant_id = p_tenant_id for update;

  if p_campos ? 'ativo' then c.ativo := coalesce((p_campos ->> 'ativo')::boolean, false); end if;
  if p_campos ? 'valeDe' or p_campos ? 'valeAte' then
    c.periodo_respondido := true;
    if p_campos ? 'valeDe' then c.vale_de := nullif(p_campos ->> 'valeDe', '')::date; end if;
    if p_campos ? 'valeAte' then c.vale_ate := nullif(p_campos ->> 'valeAte', '')::date; end if;
  end if;
  if p_campos ? 'prazoHoras' or p_campos ? 'prazoMesAnteriorHoras' then
    c.prazo_respondido := true;
    if p_campos ? 'prazoHoras' then c.prazo_horas := coalesce((p_campos ->> 'prazoHoras')::integer, 24); end if;
    if p_campos ? 'prazoMesAnteriorHoras' then
      c.prazo_mes_anterior_horas := nullif(p_campos ->> 'prazoMesAnteriorHoras', '')::integer;
    end if;
  end if;
  if p_campos ? 'pixChave' then c.pix_chave := nullif(trim(p_campos ->> 'pixChave'), ''); end if;
  if p_campos ? 'pixTitular' then c.pix_titular := nullif(trim(p_campos ->> 'pixTitular'), ''); end if;
  if p_campos ? 'devolve' then
    c.reembolso_respondido := true;
    c.reembolso_ate_horas := case when (p_campos ->> 'devolve')::boolean
                                  then coalesce((p_campos ->> 'devolveAteHoras')::integer, 24) end;
  end if;

  if c.vale_ate is not null and c.vale_de is not null and c.vale_ate < c.vale_de then
    return jsonb_build_object('ok', false, 'reason', 'PERIODO_INVERTIDO');
  end if;
  -- Ligar sem valor ou sem Pix seria cobrar sem dizer quanto nem onde.
  if c.ativo and (c.pix_chave is null or not exists (select 1 from app.sinal_valores v where v.tenant_id = p_tenant_id)) then
    return jsonb_build_object('ok', false, 'reason', 'FALTA_VALOR_OU_PIX', 'sinal', app.sinal_resumo(p_tenant_id));
  end if;

  update app.sinal_config
     set ativo = c.ativo, vale_de = c.vale_de, vale_ate = c.vale_ate, prazo_horas = c.prazo_horas,
         prazo_mes_anterior_horas = c.prazo_mes_anterior_horas, pix_chave = c.pix_chave,
         pix_titular = c.pix_titular, reembolso_respondido = c.reembolso_respondido,
         reembolso_ate_horas = c.reembolso_ate_horas, periodo_respondido = c.periodo_respondido,
         prazo_respondido = c.prazo_respondido, atualizado_em = statement_timestamp()
   where tenant_id = p_tenant_id;

  return jsonb_build_object('ok', true, 'sinal', app.sinal_resumo(p_tenant_id));
exception when invalid_text_representation or check_violation or datetime_field_overflow then
  return jsonb_build_object('ok', false, 'reason', 'VALOR_INVALIDO', 'detalhe', sqlerrm);
end;
$function$;

revoke all on function app.sinal_resumo(uuid) from public, anon, authenticated;
revoke all on function app.eddy_definir_sinal(uuid, jsonb) from public, anon, authenticated;