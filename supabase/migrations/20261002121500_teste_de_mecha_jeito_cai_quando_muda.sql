-- TESTE DE MECHA: mudou o modo, o jeito de falar antigo cai.
-- Matriz de 02/10: o dono definiu MESMO_DIA com "a gente faz o teste no
-- começo, se aprovar já segue" e depois mudou para SEM_TESTE; a frase antiga
-- continuava valendo e contradizia o modo novo.

create or replace function app.eddy_definir_teste_mecha(p_tenant_id uuid, p_modo text, p_dias_antes integer, p_jeito_de_falar text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_modo text := upper(trim(coalesce(p_modo, '')));
begin
  if v_modo not in ('MESMO_DIA', 'ANTES', 'SEM_TESTE') then
    return jsonb_build_object('ok', false, 'reason', 'MODO_INVALIDO');
  end if;
  if v_modo = 'ANTES' and (p_dias_antes is null or p_dias_antes not between 1 and 60) then
    return jsonb_build_object('ok', false, 'reason', 'FALTA_QUANTOS_DIAS_ANTES');
  end if;
  insert into app.teste_mecha_config (tenant_id, modo, dias_antes, jeito_de_falar, respondido, atualizado_em)
  values (p_tenant_id, v_modo, case when v_modo = 'ANTES' then p_dias_antes end,
          nullif(trim(coalesce(p_jeito_de_falar, '')), ''), true, statement_timestamp())
  on conflict (tenant_id) do update
    set modo = excluded.modo, dias_antes = excluded.dias_antes,
        -- Mudou o modo: o jeito de falar antigo era do outro modo e cai.
        jeito_de_falar = case when excluded.modo <> app.teste_mecha_config.modo then excluded.jeito_de_falar
                              else coalesce(excluded.jeito_de_falar, app.teste_mecha_config.jeito_de_falar) end,
        respondido = true, atualizado_em = statement_timestamp();
  return jsonb_build_object('ok', true, 'agora', app.teste_mecha_resumo(p_tenant_id));
end;
$$;
