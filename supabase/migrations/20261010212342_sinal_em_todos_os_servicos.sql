-- SINAL EM TODOS OS SERVIÇOS.
--
-- 10/10/2026, PRODUÇÃO, William: "Todos os serviços, químicas, colorações,
-- progressivas, selantes, luzes, cortes, escovas." e depois "Corte entra
-- também todos os serviços". O banco só sabia "toda a química" ou um valor
-- por serviço JÁ cadastrado, e o salão dele não tinha nenhum serviço ainda.
-- Ficou gravado só a química; o Eddy disse "Corte e escova não entram" e,
-- corrigido, "corte também entra, já ajustei" -- sem gravar nada. Corte e
-- escova de dezembro sairiam sem sinal.
--
-- Agora existe o valor para TODOS os serviços (os de hoje e os que ele
-- cadastrar depois). Ordem de quem ganha: valor do serviço > química > todos.

alter table app.sinal_config
  add column if not exists valor_todos_centavos integer check (valor_todos_centavos > 0);

comment on column app.sinal_config.valor_todos_centavos is
  'Sinal de qualquer serviço (o dono disse "todos os serviços"). Valor de um serviço em sinal_valores ganha deste.';

create or replace function app.sinal_valor_do_servico(p_tenant_id uuid, p_servico_nome text)
returns integer
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_valor integer;
  v_preco integer;
  v_todos integer;
  v_quimica integer;
  v_regra integer;
begin
  select v.valor_centavos into v_valor from app.sinal_valores v
   where v.tenant_id = p_tenant_id and v.servico_chave = app.agenda_nome_comparavel(trim(p_servico_nome));
  if v_valor is not null then
    return nullif(v_valor, 0);
  end if;
  select c.valor_todos_centavos, c.valor_quimica_centavos into v_todos, v_quimica
    from app.sinal_config c where c.tenant_id = p_tenant_id;
  -- Do mais específico ao mais geral: "50 em tudo, química 100" cobra 100 na química.
  v_regra := case
    when v_quimica is not null and app.servico_e_quimica(p_servico_nome) then v_quimica
    else v_todos
  end;
  if v_regra is null then
    return null;
  end if;
  select s.base_price_minor into v_preco
    from app.services s
    join app.configuration_drafts d on d.id = s.configuration_draft_id
   where s.tenant_id = p_tenant_id
     and app.agenda_nome_comparavel(trim(s.name)) = app.agenda_nome_comparavel(trim(p_servico_nome))
   order by d.revision desc
   limit 1;
  -- Sinal nunca maior que o serviço (uma escova de R$ 40 com "sinal de 50 em tudo").
  if v_preco is not null and v_preco > 0 and v_regra > v_preco then
    return v_preco;
  end if;
  return v_regra;
end;
$function$;

create or replace function app.sinal_tem_valor(p_tenant_id uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select exists (select 1 from app.sinal_valores v where v.tenant_id = p_tenant_id and v.valor_centavos > 0)
      or exists (select 1 from app.sinal_config c where c.tenant_id = p_tenant_id
                   and (c.valor_quimica_centavos is not null or c.valor_todos_centavos is not null));
$function$;

create or replace function app.sinal_resumo(p_tenant_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'ativo', coalesce(c.ativo, false),
    'valorParaTodosOsServicos', case when c.valor_todos_centavos is null then null
                                     else 'R$ ' || app.agenda_reais_curto(c.valor_todos_centavos) end,
    'valorParaTodaQuimica', case when c.valor_quimica_centavos is null then null
                                 else 'R$ ' || app.agenda_reais_curto(c.valor_quimica_centavos) end,
    'quimicaHojeInclui', case when c.valor_quimica_centavos is null then null
                              else to_jsonb(app.sinal_servicos_quimicos(p_tenant_id)) end,
    'valores', coalesce((select jsonb_object_agg(v.servico_nome,
                                  case when v.valor_centavos = 0 then 'não cobra sinal'
                                       else 'R$ ' || app.agenda_reais_curto(v.valor_centavos) end)
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
      case when not app.sinal_tem_valor(p_tenant_id) then 'VALORES' end,
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
  -- "sinal de R$ 50 pra toda química": vale para os químicos de hoje e de amanhã.
  if p_campos ? 'valorQuimicaReais' then
    c.valor_quimica_centavos := nullif(round(coalesce((p_campos ->> 'valorQuimicaReais')::numeric, 0) * 100)::integer, 0);
  end if;
  -- "sinal de R$ 50 em todos os serviços": qualquer serviço, de hoje e de amanhã.
  if p_campos ? 'valorTodosReais' then
    c.valor_todos_centavos := nullif(round(coalesce((p_campos ->> 'valorTodosReais')::numeric, 0) * 100)::integer, 0);
  end if;
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

  if (c.valor_quimica_centavos is not null and c.valor_quimica_centavos < 0)
     or (c.valor_todos_centavos is not null and c.valor_todos_centavos < 0) then
    return jsonb_build_object('ok', false, 'reason', 'VALOR_INVALIDO');
  end if;
  if c.vale_ate is not null and c.vale_de is not null and c.vale_ate < c.vale_de then
    return jsonb_build_object('ok', false, 'reason', 'PERIODO_INVERTIDO');
  end if;

  update app.sinal_config
     set ativo = c.ativo, vale_de = c.vale_de, vale_ate = c.vale_ate, prazo_horas = c.prazo_horas,
         prazo_mes_anterior_horas = c.prazo_mes_anterior_horas, pix_chave = c.pix_chave,
         pix_titular = c.pix_titular, reembolso_respondido = c.reembolso_respondido,
         reembolso_ate_horas = c.reembolso_ate_horas, periodo_respondido = c.periodo_respondido,
         prazo_respondido = c.prazo_respondido, valor_quimica_centavos = c.valor_quimica_centavos,
         valor_todos_centavos = c.valor_todos_centavos,
         atualizado_em = statement_timestamp()
   where tenant_id = p_tenant_id;

  -- Ligar sem valor ou sem Pix seria cobrar sem dizer quanto nem onde. O resto
  -- do que ele disse fica gravado; só o ligar volta.
  if c.ativo and (c.pix_chave is null or not app.sinal_tem_valor(p_tenant_id)) then
    update app.sinal_config set ativo = false where tenant_id = p_tenant_id;
    return jsonb_build_object('ok', false, 'reason', 'FALTA_VALOR_OU_PIX',
      'gravado', 'o resto foi gravado; só não liguei', 'sinal', app.sinal_resumo(p_tenant_id));
  end if;

  return jsonb_build_object('ok', true, 'sinal', app.sinal_resumo(p_tenant_id));
exception when invalid_text_representation or check_violation or datetime_field_overflow or numeric_value_out_of_range then
  return jsonb_build_object('ok', false, 'reason', 'VALOR_INVALIDO', 'detalhe', sqlerrm);
end;
$function$;

-- "Esse não cobra" precisa de linha 0 quando uma regra geral (todos ou
-- química) pegaria o serviço; sem regra geral, basta apagar o valor dele.
create or replace function app.eddy_definir_sinal_valor(p_tenant_id uuid, p_servico text, p_valor_centavos integer)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_nome text;
  v_preco integer;
  v_regra_geral boolean;
begin
  select s.name, s.base_price_minor into v_nome, v_preco
    from app.services s
    join app.configuration_drafts d on d.id = s.configuration_draft_id
   where s.tenant_id = p_tenant_id
     and app.agenda_nome_comparavel(trim(s.name)) = app.agenda_nome_comparavel(trim(p_servico))
   order by d.revision desc
   limit 1;
  if v_nome is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_EXISTE',
      'dica', 'Se o dono falou de todos os serviços, use valorTodosReais em configurar_sinal; se falou de toda a química, valorQuimicaReais.',
      'servicos', (select to_jsonb(array_agg(distinct s.name order by s.name))
                     from app.services s
                     join app.configuration_drafts d on d.id = s.configuration_draft_id
                    where s.tenant_id = p_tenant_id
                      and d.revision = (select max(d2.revision) from app.configuration_drafts d2 where d2.tenant_id = p_tenant_id)));
  end if;

  if coalesce(p_valor_centavos, 0) <= 0 then
    select c.valor_todos_centavos is not null
           or (c.valor_quimica_centavos is not null and app.servico_e_quimica(v_nome))
      into v_regra_geral
      from app.sinal_config c where c.tenant_id = p_tenant_id;
    if coalesce(v_regra_geral, false) then
      insert into app.sinal_valores (tenant_id, servico_nome, valor_centavos)
      values (p_tenant_id, v_nome, 0)
      on conflict (tenant_id, servico_chave)
      do update set servico_nome = excluded.servico_nome, valor_centavos = 0, atualizado_em = statement_timestamp();
    else
      delete from app.sinal_valores
       where tenant_id = p_tenant_id and servico_chave = app.agenda_nome_comparavel(trim(v_nome));
    end if;
    return jsonb_build_object('ok', true, 'servico', v_nome, 'cobra', false, 'sinal', app.sinal_resumo(p_tenant_id));
  end if;

  if v_preco is not null and p_valor_centavos > v_preco then
    return jsonb_build_object('ok', false, 'reason', 'SINAL_MAIOR_QUE_O_PRECO',
      'preco', 'R$ ' || app.agenda_reais_curto(v_preco));
  end if;

  insert into app.sinal_valores (tenant_id, servico_nome, valor_centavos)
  values (p_tenant_id, v_nome, p_valor_centavos)
  on conflict (tenant_id, servico_chave)
  do update set servico_nome = excluded.servico_nome, valor_centavos = excluded.valor_centavos,
                atualizado_em = statement_timestamp();

  return jsonb_build_object('ok', true, 'servico', v_nome, 'cobra', true,
    'valor', 'R$ ' || app.agenda_reais_curto(p_valor_centavos), 'sinal', app.sinal_resumo(p_tenant_id));
end;
$function$;

-- O valor de "todos" também é um valor que o dono disse (trava de preço inventado).
create or replace function app.eddy_valores_gravados(p_tenant_id uuid)
returns numeric[]
language sql
stable security definer
set search_path to ''
as $function$
  select coalesce(array_agg(distinct v), '{}')
    from (
      select s.base_price_minor / 100.0 v from app.services s
       where s.tenant_id = p_tenant_id and s.base_price_minor is not null
      union all
      select sv.price_minor / 100.0 from app.service_variations sv
       where sv.tenant_id = p_tenant_id and sv.price_minor is not null
      union all
      select tf.extra_price_minor / 100.0 from app.tone_families tf
       where tf.tenant_id = p_tenant_id and tf.extra_price_minor is not null
      union all
      select replace(m[1], ',', '.')::numeric
        from app.agent_policies ap, regexp_matches(ap.body, '(\d{1,5}(?:[.,]\d{1,2})?)', 'g') m
       where ap.tenant_id = p_tenant_id
      union all
      select v.valor_centavos / 100.0 from app.sinal_valores v
       where v.tenant_id = p_tenant_id and v.valor_centavos > 0
      union all
      select c.valor_quimica_centavos / 100.0 from app.sinal_config c
       where c.tenant_id = p_tenant_id and c.valor_quimica_centavos is not null
      union all
      select c.valor_todos_centavos / 100.0 from app.sinal_config c
       where c.tenant_id = p_tenant_id and c.valor_todos_centavos is not null
    ) x;
$function$;

revoke all on function app.sinal_valor_do_servico(uuid, text) from public, anon, authenticated;
revoke all on function app.sinal_tem_valor(uuid) from public, anon, authenticated;
revoke all on function app.sinal_resumo(uuid) from public, anon, authenticated;
revoke all on function app.eddy_definir_sinal(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.eddy_definir_sinal_valor(uuid, text, integer) from public, anon, authenticated;
revoke all on function app.eddy_valores_gravados(uuid) from public, anon, authenticated;
