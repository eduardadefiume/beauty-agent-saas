-- SINAL PARA AGENDAR, PASSO 1: O QUE O DONO DECIDE E O PRAZO.
--
-- 30/09, Duda: o sinal é o que vai vender. Cada DONO decide no Eddy (a Duda
-- não decide pelo dono):
--   * em quais procedimentos cobra e quanto (valor fixo);
--   * se vale sempre ou só num período (o William: só em dezembro);
--   * quanto tempo a cliente tem para pagar (padrão 24h) e se dá mais tempo
--     quando ela marca num mês para o outro (o William: 48h de novembro para
--     dezembro, 24h dentro de dezembro);
--   * a chave Pix e o nome que aparece;
--   * se devolve quando ela desmarca, e com quantas horas de antecedência.
-- Fixo no produto: pagar até 2h antes do horário (prazo nunca passa disso);
-- faltando menos que isso, o horário é marcado sem sinal.
--
-- O valor fica pelo NOME do serviço: o id do serviço muda a cada publicação
-- (Salão do William no DEV: 11 ids para 11 versões do mesmo "Luzes").

create table if not exists app.sinal_config (
  tenant_id uuid primary key references app.tenants(id) on delete cascade,
  ativo boolean not null default false,
  vale_de date,
  vale_ate date,
  prazo_horas integer not null default 24 check (prazo_horas between 1 and 168),
  prazo_mes_anterior_horas integer check (prazo_mes_anterior_horas between 1 and 168),
  pagar_ate_antes_min integer not null default 120 check (pagar_ate_antes_min between 0 and 1440),
  reembolso_ate_horas integer check (reembolso_ate_horas between 0 and 720),
  reembolso_respondido boolean not null default false,
  pix_chave text,
  pix_titular text,
  atualizado_em timestamptz not null default statement_timestamp(),
  check (vale_ate is null or vale_de is null or vale_ate >= vale_de)
);

create table if not exists app.sinal_valores (
  tenant_id uuid not null references app.tenants(id) on delete cascade,
  servico_nome text not null,
  servico_chave text generated always as (app.agenda_nome_comparavel(trim(servico_nome))) stored,
  valor_centavos integer not null check (valor_centavos > 0),
  atualizado_em timestamptz not null default statement_timestamp(),
  primary key (tenant_id, servico_chave)
);

alter table app.sinal_config enable row level security;
alter table app.sinal_valores enable row level security;
revoke all on app.sinal_config, app.sinal_valores from public, anon, authenticated;

-- O resumo que o Eddy mostra ao dono e usa para saber o que falta perguntar.
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
      case when c.pix_chave is null then 'PIX' end,
      case when not coalesce(c.reembolso_respondido, false) then 'DEVOLUCAO' end
    ], null)))
  from (select 1) um
  left join app.sinal_config c on c.tenant_id = p_tenant_id;
$function$;

-- O Eddy grava o que o dono respondeu. Só mexe no que veio (jsonb parcial).
-- Chaves: ativo, valeDe, valeAte (AAAA-MM-DD ou null), prazoHoras,
-- prazoMesAnteriorHoras (null = igual), pixChave, pixTitular,
-- devolve (bool), devolveAteHoras.
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
  if p_campos ? 'valeDe' then c.vale_de := nullif(p_campos ->> 'valeDe', '')::date; end if;
  if p_campos ? 'valeAte' then c.vale_ate := nullif(p_campos ->> 'valeAte', '')::date; end if;
  if p_campos ? 'prazoHoras' then c.prazo_horas := (p_campos ->> 'prazoHoras')::integer; end if;
  if p_campos ? 'prazoMesAnteriorHoras' then
    c.prazo_mes_anterior_horas := nullif(p_campos ->> 'prazoMesAnteriorHoras', '')::integer;
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

  update app.sinal_config
     set ativo = c.ativo, vale_de = c.vale_de, vale_ate = c.vale_ate, prazo_horas = c.prazo_horas,
         prazo_mes_anterior_horas = c.prazo_mes_anterior_horas, pix_chave = c.pix_chave,
         pix_titular = c.pix_titular, reembolso_respondido = c.reembolso_respondido,
         reembolso_ate_horas = c.reembolso_ate_horas, atualizado_em = statement_timestamp()
   where tenant_id = p_tenant_id;

  return jsonb_build_object('ok', true, 'sinal', app.sinal_resumo(p_tenant_id));
exception when invalid_text_representation or check_violation or datetime_field_overflow then
  return jsonb_build_object('ok', false, 'reason', 'VALOR_INVALIDO', 'detalhe', sqlerrm);
end;
$function$;

-- Valor do sinal de um procedimento. valor 0 ou null = esse não cobra.
create or replace function app.eddy_definir_sinal_valor(p_tenant_id uuid, p_servico text, p_valor_centavos integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_nome text;
  v_preco integer;
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
      'servicos', (select to_jsonb(array_agg(distinct s.name order by s.name))
                     from app.services s
                     join app.configuration_drafts d on d.id = s.configuration_draft_id
                    where s.tenant_id = p_tenant_id
                      and d.revision = (select max(d2.revision) from app.configuration_drafts d2 where d2.tenant_id = p_tenant_id)));
  end if;

  if coalesce(p_valor_centavos, 0) <= 0 then
    delete from app.sinal_valores
     where tenant_id = p_tenant_id and servico_chave = app.agenda_nome_comparavel(trim(v_nome));
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

-- A CONTA DO PRAZO. Usada pela reserva e testável sozinha.
--   prazo = 24h (ou o que o dono disse); se ela marca num mês para o mês
--   seguinte (ou depois) e o dono deu prazo maior para isso, vale o maior;
--   nunca passa de "X min antes do horário" (padrão 2h);
--   se nem 30 min sobram, marca sem sinal.
create or replace function app.sinal_da_reserva(
  p_tenant_id uuid, p_servico_nome text, p_inicio timestamptz, p_agora timestamptz default statement_timestamp())
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

  select v.valor_centavos into v_valor from app.sinal_valores v
   where v.tenant_id = p_tenant_id and v.servico_chave = app.agenda_nome_comparavel(trim(p_servico_nome));
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

revoke all on function app.sinal_resumo(uuid) from public, anon, authenticated;
revoke all on function app.eddy_definir_sinal(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.eddy_definir_sinal_valor(uuid, text, integer) from public, anon, authenticated;
revoke all on function app.sinal_da_reserva(uuid, text, timestamptz, timestamptz) from public, anon, authenticated;

-- Pontes para as edge functions.
create or replace function public.eddy_definir_sinal(p_tenant_id uuid, p_campos jsonb)
 returns jsonb language sql security definer set search_path to ''
as $function$ select app.eddy_definir_sinal(p_tenant_id, p_campos); $function$;
create or replace function public.eddy_definir_sinal_valor(p_tenant_id uuid, p_servico text, p_valor_centavos integer)
 returns jsonb language sql security definer set search_path to ''
as $function$ select app.eddy_definir_sinal_valor(p_tenant_id, p_servico, p_valor_centavos); $function$;
create or replace function public.sinal_resumo(p_tenant_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$ select app.sinal_resumo(p_tenant_id); $function$;

revoke all on function public.eddy_definir_sinal(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.eddy_definir_sinal_valor(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.sinal_resumo(uuid) from public, anon, authenticated;
grant execute on function public.eddy_definir_sinal(uuid, jsonb) to service_role;
grant execute on function public.eddy_definir_sinal_valor(uuid, text, integer) to service_role;
grant execute on function public.sinal_resumo(uuid) to service_role;

notify pgrst, 'reload schema';