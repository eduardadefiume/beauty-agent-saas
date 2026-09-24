-- PAUSA ACOMPANHADA E DECISAO, NAO ERRO.
--
-- 24/09/2026, teste com dono-robo. O dono disse que nas mechas fica de olho
-- durante os 45 minutos (pausa que NAO libera a profissional), isso foi
-- gravado, publicado -- e o Eddy perguntou de novo. A pendencia
-- SERVICO_PAUSA_LIBERA nasceu quando toda pausa sem liberar era erro de
-- cadastro; desde 20260924170711 pode ser decisao do dono.
--
-- A decisao passa a ficar no proprio passo: pausa que nao libera, gravada pelo
-- dono, se chama "Pausa acompanhada". O nome viaja com o clone do rascunho
-- (a chave por id de servico nao viajaria), e a pendencia ignora pausa
-- acompanhada.

do $mig$
declare
  v_def text := pg_get_functiondef('app.onboarding_definir_pausa(uuid, text, integer, boolean, boolean)'::regprocedure);
  c_corrige constant text := E'         set releases_member = v_libera, updated_at = statement_timestamp()';
  c_nome constant text := E'    p_tenant_id, v_rascunho, v_servico, ''Pausa'', v_ativa.position + 1,';
begin
  if position(c_corrige in v_def) = 0 or position(c_nome in v_def) = 0 then
    raise exception 'ancoras de onboarding_definir_pausa sumiram';
  end if;
  v_def := replace(v_def, c_corrige,
    E'         set releases_member = v_libera,\n'
    || E'             name = case when v_libera then ''Pausa'' else ''Pausa acompanhada'' end,\n'
    || E'             updated_at = statement_timestamp()');
  v_def := replace(v_def, c_nome,
    E'    p_tenant_id, v_rascunho, v_servico,\n'
    || E'    case when v_libera then ''Pausa'' else ''Pausa acompanhada'' end, v_ativa.position + 1,');
  execute v_def;
end
$mig$;

do $mig$
declare
  v_def text := pg_get_functiondef('app.onboarding_pendencies(uuid)'::regprocedure);
  c_ancora constant text := E'     and s.pausas_que_liberam = 0\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora da SERVICO_PAUSA_LIBERA sumiu';
  end if;
  execute replace(v_def, c_ancora,
    c_ancora
    || E'     and not exists (select 1 from app.service_steps st\n'
    || E'                      where st.service_id = s.id and st.kind = ''PASSIVE''\n'
    || E'                        and st.name = ''Pausa acompanhada'')\n');
end
$mig$;
