-- SINAL PARA TODA A QUÍMICA.
--
-- 02/10, DEV, William-robô configurando do zero: "sinal sim mas só pra
-- química", "50 reais". O sinal só podia ser gravado por SERVIÇO, e o salão
-- ainda não tinha serviço nenhum. Não havia onde guardar -- e o Eddy disse
-- "o valor de R$ 50 pra química eu guardei aqui". Não guardou.
--
-- Agora o dono pode dar um valor de sinal para toda a química. Vale para
-- qualquer serviço químico que exista hoje ou que ele cadastrar depois. O
-- valor por serviço continua valendo e ganha da regra geral; valor 0 num
-- serviço = "esse não cobra" (exceção à regra da química).

alter table app.sinal_config add column if not exists valor_quimica_centavos integer
  check (valor_quimica_centavos is null or valor_quimica_centavos > 0);

alter table app.sinal_valores drop constraint if exists sinal_valores_valor_centavos_check;
alter table app.sinal_valores add constraint sinal_valores_valor_centavos_check check (valor_centavos >= 0);

-- O que é química para o sinal. Corte, escova simples, hidratação,
-- reconstrução, nutrição e cauterização NÃO são; o teste de mecha também não
-- (ele vai junto do procedimento).
create or replace function app.servico_e_quimica(p_nome text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  with n as (select translate(lower(coalesce(p_nome, '')), 'áàâãéêíóôõúç', 'aaaaeeiooouc') t)
  select case
    -- "Teste de mecha" sozinho e "Adicional de ..." não são o procedimento.
    when n.t ~ '^\s*(teste|adicional)' then false
    else n.t ~ '(luzes|mecha|morena iluminada|iluminad|balaiagem|balayage|ombre|descolor|platinad|colora|tintura|tonaliz|matiz|gloss|progressiva|alisament|selante|botox|relaxament|definitiva|queratin|realinhament|blindagem|escova (inteligente|marroquina|japonesa|progressiva|definitiva)|permanente|ondula|reflexo|raiz)'
  end
  from n;
$$;
revoke all on function app.servico_e_quimica(text) from public, anon, authenticated;

-- Os serviços do salão (último rascunho) que entram na regra da química.
create or replace function app.sinal_servicos_quimicos(p_tenant_id uuid)
returns text[]
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(array_agg(distinct s.name order by s.name), '{}')
    from app.services s
    join app.configuration_drafts d on d.id = s.configuration_draft_id
   where s.tenant_id = p_tenant_id
     and d.revision = (select max(d2.revision) from app.configuration_drafts d2 where d2.tenant_id = p_tenant_id)
     and app.servico_e_quimica(s.name);
$$;
revoke all on function app.sinal_servicos_quimicos(uuid) from public, anon, authenticated;

-- Valor do sinal de um serviço: o do serviço ganha; senão o da química, se ele
-- for químico. 0 no serviço = exceção, não cobra. Nunca maior que o preço.
create or replace function app.sinal_valor_do_servico(p_tenant_id uuid, p_servico_nome text)
returns integer
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_valor integer;
  v_preco integer;
  v_quimica integer;
begin
  select v.valor_centavos into v_valor from app.sinal_valores v
   where v.tenant_id = p_tenant_id and v.servico_chave = app.agenda_nome_comparavel(trim(p_servico_nome));
  if v_valor is not null then
    return nullif(v_valor, 0);
  end if;
  select c.valor_quimica_centavos into v_quimica from app.sinal_config c where c.tenant_id = p_tenant_id;
  if v_quimica is null or not app.servico_e_quimica(p_servico_nome) then
    return null;
  end if;
  select s.base_price_minor into v_preco
    from app.services s
    join app.configuration_drafts d on d.id = s.configuration_draft_id
   where s.tenant_id = p_tenant_id
     and app.agenda_nome_comparavel(trim(s.name)) = app.agenda_nome_comparavel(trim(p_servico_nome))
   order by d.revision desc
   limit 1;
  if v_preco is not null and v_preco > 0 and v_quimica > v_preco then
    return v_preco;
  end if;
  return v_quimica;
end;
$$;
revoke all on function app.sinal_valor_do_servico(uuid, text) from public, anon, authenticated;

create or replace function app.sinal_tem_valor(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (select 1 from app.sinal_valores v where v.tenant_id = p_tenant_id and v.valor_centavos > 0)
      or exists (select 1 from app.sinal_config c where c.tenant_id = p_tenant_id and c.valor_quimica_centavos is not null);
$$;
revoke all on function app.sinal_tem_valor(uuid) from public, anon, authenticated;

create or replace function app.sinal_da_reserva(p_tenant_id uuid, p_servico_nome text, p_inicio timestamp with time zone, p_agora timestamp with time zone default statement_timestamp())
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  c app.sinal_config%rowtype;
  v_valor integer;
  v_tz text;
  v_horas integer;
  v_prazo timestamptz;
  v_limite timestamptz;
begin
  select * into c from app.sinal_config where tenant_id = p_tenant_id;
  if c.tenant_id is null or not c.ativo then
    return jsonb_build_object('cobra', false, 'porque', 'SINAL_DESLIGADO');
  end if;

  v_valor := app.sinal_valor_do_servico(p_tenant_id, p_servico_nome);
  if v_valor is null then
    return jsonb_build_object('cobra', false, 'porque', 'SERVICO_SEM_SINAL');
  end if;

  select coalesce(u.timezone, 'America/Sao_Paulo') into v_tz
    from app.units u where u.tenant_id = p_tenant_id order by u.created_at limit 1;
  v_tz := coalesce(v_tz, 'America/Sao_Paulo');

  if (c.vale_de is not null and (p_inicio at time zone v_tz)::date < c.vale_de)
     or (c.vale_ate is not null and (p_inicio at time zone v_tz)::date > c.vale_ate) then
    return jsonb_build_object('cobra', false, 'porque', 'FORA_DO_PERIODO');
  end if;

  v_horas := case
    when c.prazo_mes_anterior_horas is not null
     and date_trunc('month', p_agora at time zone v_tz) < date_trunc('month', p_inicio at time zone v_tz)
    then c.prazo_mes_anterior_horas
    else c.prazo_horas end;
  v_limite := p_inicio - make_interval(mins => c.pagar_ate_antes_min);
  v_prazo := least(p_agora + make_interval(hours => v_horas), v_limite);

  if v_prazo < p_agora + interval '30 minutes' then
    return jsonb_build_object('cobra', false, 'porque', 'EM_CIMA_DA_HORA');
  end if;

  return jsonb_build_object('cobra', true, 'valorCentavos', v_valor, 'prazo', v_prazo,
    'prazoMinutos', ceil(extract(epoch from (v_prazo - p_agora)) / 60)::integer,
    'horasDaRegra', v_horas, 'cortadoPeloHorario', v_prazo = v_limite);
end;
$function$;

create or replace function app.sinal_resumo(p_tenant_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'ativo', coalesce(c.ativo, false),
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

  if c.valor_quimica_centavos is not null and c.valor_quimica_centavos < 0 then
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

-- Valor por serviço. 0 num serviço químico com regra da química = exceção
-- ("a tonalização não cobra"); 0 nos outros = tira o sinal dele.
create or replace function app.eddy_definir_sinal_valor(p_tenant_id uuid, p_servico text, p_valor_centavos integer)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_nome text;
  v_preco integer;
  v_quimica integer;
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
      'dica', 'Se o dono falou de toda a química, use valorQuimicaReais em configurar_sinal.',
      'servicos', (select to_jsonb(array_agg(distinct s.name order by s.name))
                     from app.services s
                     join app.configuration_drafts d on d.id = s.configuration_draft_id
                    where s.tenant_id = p_tenant_id
                      and d.revision = (select max(d2.revision) from app.configuration_drafts d2 where d2.tenant_id = p_tenant_id)));
  end if;

  if coalesce(p_valor_centavos, 0) <= 0 then
    select c.valor_quimica_centavos into v_quimica from app.sinal_config c where c.tenant_id = p_tenant_id;
    if v_quimica is not null and app.servico_e_quimica(v_nome) then
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

revoke all on function app.sinal_da_reserva(uuid, text, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function app.sinal_resumo(uuid) from public, anon, authenticated;
revoke all on function app.eddy_definir_sinal(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.eddy_definir_sinal_valor(uuid, text, integer) from public, anon, authenticated;

-- A trava do "anotei R$ X" do Eddy confere aqui. Valor de sinal também é
-- valor gravado (antes, "sinal de R$ 50" gravado de verdade seria barrado, e
-- não havia onde gravar o da química).
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
    ) x;
$function$;
revoke all on function app.eddy_valores_gravados(uuid) from public, anon, authenticated;
