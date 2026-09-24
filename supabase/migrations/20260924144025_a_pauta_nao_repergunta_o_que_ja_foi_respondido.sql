-- A PAUTA NAO REPERGUNTA O QUE JA FOI RESPONDIDO.
--
-- 24/09/2026, teste com dono-robo. O dono disse "sem sinal; desmarcou com
-- menos de 24h paga 50%", o Eddy criou a regra de cancelamento em rascunho --
-- e a pauta seguiu listando REGRA:CANCELAMENTO e REGRA:SINAL, porque so
-- contava regra ACTIVE. Rascunho esperando publicar ja e resposta, e "nao
-- quero sinal" (agent_scope.pede_sinal = false) tambem.

do $mig$
declare
  v_def text := pg_get_functiondef('app.onboarding_pendencies(uuid)'::regprocedure);
  c_ancora constant text := E'      where ap.tenant_id = p_tenant_id and ap.status = ''ACTIVE'' and ap.topic::text = t.topico\n   )';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de onboarding_pendencies sumiu';
  end if;
  v_def := replace(v_def, c_ancora,
    E'      where ap.tenant_id = p_tenant_id and ap.topic::text = t.topico\n'
    || E'        and (ap.status = ''ACTIVE'' or (ap.status = ''DRAFT'' and ap.aguarda_publicacao))\n'
    || E'   )\n'
    || E'     and not (t.topico = ''SINAL'' and exists (\n'
    || E'       select 1 from app.agent_scope sc\n'
    || E'        where sc.tenant_id = p_tenant_id and sc.respondido_em is not null and not sc.pede_sinal))');
  execute v_def;
end
$mig$;
