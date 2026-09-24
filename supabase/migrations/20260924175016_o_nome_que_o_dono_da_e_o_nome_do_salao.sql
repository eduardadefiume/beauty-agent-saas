-- O NOME QUE O DONO DA E O NOME DO SALAO.
--
-- 24/09/2026, teste com dono-robo. O dono disse ao Eddy que o salao se chama
-- "Studio Rogerio Hair", e o Eddy gravou em units.name. Mas o lembrete de
-- vespera, a finalizacao do agendamento, o contexto da atendente e o exemplo
-- que o Eddy mostra leem tenants.display_name -- que continuava com o nome de
-- cadastro ("Robo 1 (teste do Eddy)"; no piloto seria "S-William"). A cliente
-- receberia "Lembrando do seu horario amanha ... no S-William".
--
-- O nome que o dono da passa a valer para os dois, daqui para frente. Sem
-- acerto retroativo: nos saloes de teste o nome de cadastro e o rotulo que a
-- Eduarda usa para distingui-los ("Salao Teste (S-Eduarda)").

do $mig$
declare
  v_def text := pg_get_functiondef('app.onboarding_registrar_identidade(uuid, text, text, text)'::regprocedure);
  c_ancora constant text := E'   where id = v_unidade;\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de onboarding_registrar_identidade sumiu';
  end if;
  execute replace(v_def, c_ancora,
    c_ancora
    || E'\n  -- O nome que o dono deu e o nome que a cliente le no lembrete e na\n'
    || E'  -- finalizacao (20260924: estava saindo o nome de cadastro).\n'
    || E'  update app.tenants\n'
    || E'     set display_name = v_nome, updated_at = statement_timestamp()\n'
    || E'   where id = p_tenant_id and display_name is distinct from v_nome;\n');
end
$mig$;
