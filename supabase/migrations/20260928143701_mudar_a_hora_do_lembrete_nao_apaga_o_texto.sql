-- MUDAR A HORA DO LEMBRETE NAO APAGA O TEXTO.
--
-- 28/09/2026, teste com dono-robo: o lembrete tinha texto proprio (interfone,
-- estacionamento, "responde OK"). O dono pediu "muda pra sair as 19h", o Eddy
-- mandou so a hora e o texto virou null: o update gravava o texto que veio
-- (nenhum) por cima do que havia. A cliente voltaria a receber o modelo
-- padrao sem ninguem saber.
--
-- Agora: sem texto novo, o atual fica. Voltar ao modelo padrao e um pedido
-- explicito (p_voltar_ao_padrao).

drop function if exists public.eddy_definir_lembrete(uuid, boolean, integer, text);
drop function if exists app.eddy_definir_lembrete(uuid, boolean, integer, text);

create function app.eddy_definir_lembrete(
  p_tenant_id uuid,
  p_quer boolean,
  p_hora integer default null,
  p_texto_desejado text default null,
  p_voltar_ao_padrao boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_texto text := nullif(trim(coalesce(p_texto_desejado, '')), '');
  v_final text;
begin
  if p_quer is null then
    return jsonb_build_object('ok', false, 'reason', 'DIGA_SE_ELE_QUER');
  end if;
  if p_hora is not null and p_hora not between 8 and 21 then
    return jsonb_build_object('ok', false, 'reason', 'HORA_FORA_DE_8_A_21');
  end if;
  if v_texto is not null and coalesce(p_voltar_ao_padrao, false) then
    return jsonb_build_object('ok', false, 'reason', 'TEXTO_NOVO_OU_MODELO_PADRAO_ESCOLHA_UM');
  end if;

  -- Hora escrita no texto vale para uma cliente so. Cada uma recebe a dela.
  if v_texto is not null and v_texto not like '%{hora}%'
     and v_texto ~* '(\m\d{1,2}\s*h\M|\m\d{1,2}h\d{2}\M|\m\d{1,2}:\d{2}\M)' then
    return jsonb_build_object('ok', false, 'reason', 'TEXTO_COM_HORA_FIXA',
      'comoResolver', 'Troque a hora escrita por {hora}. Pode usar tambem {nome}, {data} e {salao}: cada cliente recebe os dela.');
  end if;

  update app.agent_scope
     set lembra_da_vespera = p_quer,
         lembrete_hora_local = coalesce(p_hora, lembrete_hora_local),
         lembrete_texto_desejado = case
                                     when coalesce(p_voltar_ao_padrao, false) then null
                                     else coalesce(v_texto, lembrete_texto_desejado)
                                   end,
         lembrete_definido_em = statement_timestamp(),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id
  returning lembrete_texto_desejado into v_final;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'PERGUNTE_ANTES_O_QUE_O_AGENTE_FAZ');
  end if;

  if v_texto is not null then
    insert into app.audit_logs (
      tenant_id, actor_type, actor_id, action, entity_type, entity_id, correlation_id, result, metadata_minimized
    ) values (
      p_tenant_id, 'SYSTEM', null, 'LEMBRETE_TEXTO_PROPRIO_PEDIDO', 'agent_scope', null,
      encode(extensions.gen_random_bytes(16), 'hex'), 'SUCCESS', jsonb_build_object('texto', v_texto)
    );
  end if;

  return jsonb_build_object(
    'ok', true, 'lembra', p_quer,
    'hora', (select lembrete_hora_local from app.agent_scope where tenant_id = p_tenant_id),
    'textoProprioPedido', v_final is not null,
    'textoQueVaiSair', coalesce(v_final, 'o modelo padrão'));
end;
$function$;

create function public.eddy_definir_lembrete(
  p_tenant_id uuid,
  p_quer boolean,
  p_hora integer default null,
  p_texto_desejado text default null,
  p_voltar_ao_padrao boolean default false)
returns jsonb
language sql
security definer
set search_path to ''
as $function$ select app.eddy_definir_lembrete(p_tenant_id, p_quer, p_hora, p_texto_desejado, p_voltar_ao_padrao); $function$;

revoke all on function app.eddy_definir_lembrete(uuid, boolean, integer, text, boolean) from public, anon, authenticated;
revoke all on function public.eddy_definir_lembrete(uuid, boolean, integer, text, boolean) from public, anon, authenticated;
grant execute on function public.eddy_definir_lembrete(uuid, boolean, integer, text, boolean) to service_role;
