-- A ATENDENTE VE PRECO POR VARIACAO E "A PARTIR DE".
--
-- 24/09/2026, teste com cliente-robo. O dono cadastrou "escova curta 70, media
-- 90, longa 120" -- servico sem preco base, com tres variacoes. A cliente
-- perguntou quanto e a escova e ouviu "nao tem valor fechado, depende do
-- cabelo". O snapshot publicado tinha as variacoes e price_is_floor; o
-- catalogo que build_agent_context monta so levava base_price_minor.

do $mig$
declare
  v_def text := pg_get_functiondef('app.build_agent_context(uuid, integer)'::regprocedure);
  c_ancora constant text := E'      ''requiresStrandTest'', coalesce((s->>''requires_strand_test'')::boolean, false)\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora do catalogo em build_agent_context sumiu';
  end if;
  if position('''variations''' in v_def) > 0 then
    raise exception 'build_agent_context ja tem variations';
  end if;
  execute replace(v_def, c_ancora,
    E'      ''requiresStrandTest'', coalesce((s->>''requires_strand_test'')::boolean, false),\n'
    || E'      -- "a partir de": o preco base e o piso, nao o preco.\n'
    || E'      ''priceIsFloor'', coalesce((s->>''price_is_floor'')::boolean, false),\n'
    || E'      ''variations'', (\n'
    || E'        select jsonb_agg(jsonb_build_object(\n'
    || E'                 ''name'', v->>''name'',\n'
    || E'                 ''priceMinor'', (v->>''price_minor'')::bigint)\n'
    || E'               order by (v->>''price_minor'')::bigint)\n'
    || E'          from jsonb_array_elements(coalesce(s->''variations'', ''[]''::jsonb)) v\n'
    || E'         where coalesce(v->>''status'', ''ACTIVE'') = ''ACTIVE'')\n');
end
$mig$;

-- E O "A PARTIR DE" QUE O EDDY DIZIA TER GRAVADO. No mesmo teste o dono
-- disse "mechas a partir de 450" e o Eddy respondeu "Mechas ... R$450 (a
-- partir de), certinho" -- com price_is_floor = false no banco. criar_servico
-- nao tinha como marcar piso, e definir_preco pede um id que so aparece para
-- servico sem preco. eddy_marcar_piso marca pelo nome, no rascunho aberto.

create or replace function app.eddy_marcar_piso(p_tenant_id uuid, p_servico text, p_piso boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
  v_id uuid;
begin
  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  update app.services s
     set price_is_floor = coalesce(p_piso, false), updated_at = statement_timestamp()
   where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_rascunho
     and s.status = 'ACTIVE' and lower(s.name) = lower(trim(coalesce(p_servico, '')))
  returning s.id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_EXISTE', 'servico', p_servico);
  end if;
  return jsonb_build_object('ok', true, 'servico', p_servico, 'aPartirDe', coalesce(p_piso, false));
end;
$fn$;

revoke all on function app.eddy_marcar_piso(uuid, text, boolean) from public, anon, authenticated;

create or replace function public.eddy_marcar_piso(p_tenant_id uuid, p_servico text, p_piso boolean)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_marcar_piso(p_tenant_id, p_servico, p_piso); $$;

revoke all on function public.eddy_marcar_piso(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.eddy_marcar_piso(uuid, text, boolean) to service_role;

-- O resumo que o Eddy le para confirmar mostra o piso: sem isso ele confirmaria
-- "a partir de" olhando so o numero.
do $mig$
declare
  v_def text := pg_get_functiondef('app.eddy_cadastro_resumido(uuid)'::regprocedure);
  c_de constant text := E'|| coalesce('' R$'' || (s.base_price_minor / 100)::text, '''')';
  c_para constant text := E'|| coalesce(case when s.price_is_floor then '' a partir de R$'' else '' R$'' end || (s.base_price_minor / 100)::text, '''')';
begin
  if position(c_de in v_def) = 0 then
    raise exception 'ancora do preco em eddy_cadastro_resumido sumiu';
  end if;
  execute replace(v_def, c_de, c_para);
end
$mig$;
