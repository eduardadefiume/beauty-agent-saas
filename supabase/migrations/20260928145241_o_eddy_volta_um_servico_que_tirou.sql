-- O EDDY VOLTA UM SERVICO QUE TIROU.
--
-- 28/09/2026, teste com dono-robo: "tira o selante" -> "Tirei. Se quiser de
-- volta, e so falar." Ele falou ("volta o selante com o mesmo preco") e o Eddy
-- nao tinha como: pediu de novo preco e tempo que o banco ainda guardava.
-- Desativar nunca apagou nada; agora da para desfazer.

create or replace function app.eddy_reativar_servico(p_tenant_id uuid, p_nome text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_origem uuid;
  v_id     uuid;
  v_alvo   uuid;
  v_nome   text := nullif(trim(coalesce(p_nome, '')), '');
  v_quantos int;
  v_preco  integer;
begin
  if v_nome is null then
    return jsonb_build_object('ok', false, 'reason', 'NOME_NAO_INFORMADO');
  end if;

  select d.id into v_origem
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id
   order by (d.status = 'DRAFT') desc, d.revision desc limit 1;

  if exists (select 1 from app.services s
              where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_origem
                and s.status = 'ACTIVE' and lower(s.name) = lower(v_nome)) then
    return jsonb_build_object('ok', false, 'reason', 'JA_ESTA_NO_CATALOGO', 'procurado', v_nome);
  end if;

  select count(*) into v_quantos
    from app.services s
   where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_origem
     and s.status = 'INACTIVE' and lower(s.name) = lower(v_nome);
  if v_quantos = 0 then
    return jsonb_build_object('ok', false, 'reason', 'NAO_HA_SERVICO_TIRADO_COM_ESSE_NOME', 'procurado', v_nome);
  end if;
  if v_quantos > 1 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_AMBIGUO', 'procurado', v_nome);
  end if;

  select s.id into v_id
    from app.services s
   where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_origem
     and s.status = 'INACTIVE' and lower(s.name) = lower(v_nome);

  v_alvo := app.servico_no_rascunho(p_tenant_id, v_id);
  if v_alvo is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO_NO_RASCUNHO');
  end if;

  update app.services
     set status = 'ACTIVE'::app.record_status,
         bookable = true,
         updated_at = statement_timestamp()
   where id = v_alvo and tenant_id = p_tenant_id
  returning name, base_price_minor into v_nome, v_preco;

  return jsonb_build_object(
    'ok', true, 'servico', v_nome, 'precoCentavos', v_preco,
    'minutosTotais', (select sum(st.duration_minutes) from app.service_steps st where st.service_id = v_alvo));
end;
$function$;

create or replace function public.eddy_reativar_servico(p_tenant_id uuid, p_nome text)
returns jsonb
language sql
security definer
set search_path to ''
as $function$ select app.eddy_reativar_servico(p_tenant_id, p_nome); $function$;

revoke all on function app.eddy_reativar_servico(uuid, text) from public, anon, authenticated;
revoke all on function public.eddy_reativar_servico(uuid, text) from public, anon, authenticated;
grant execute on function public.eddy_reativar_servico(uuid, text) to service_role;
