-- O HORARIO DE FECHAR E O LIMITE DO ULTIMO ATENDIMENTO.
--
-- 24/09/2026, teste com dono-robo. Cadastro completo, dono manda publicar, e o
-- Eddy passa para uma pessoa: "Isso aqui eu nao consigo fazer por aqui". A
-- publicacao exige LATEST_END (unit_service_limits: ate que horas o
-- atendimento pode terminar em cada dia) e nenhuma ferramenta do Eddy grava
-- isso. Todo salao configurado por conversa travaria no ultimo passo.
--
-- O padrao certo nao precisa de pergunta: o atendimento termina ate o salao
-- fechar. onboarding_definir_horario_funcionamento passa a gravar o limite
-- junto com o horario, e os rascunhos abertos que tem horario sem limite
-- ganham o mesmo valor agora.

do $mig$
declare
  v_def text := pg_get_functiondef('app.onboarding_definir_horario_funcionamento(uuid, jsonb)'::regprocedure);
  c_apaga constant text := E'  delete from app.operating_hours\n   where tenant_id = p_tenant_id and configuration_draft_id = v_rascunho;\n';
  c_insere constant text := E'    on conflict do nothing;\n';
begin
  if position(c_apaga in v_def) = 0 or position(c_insere in v_def) = 0 then
    raise exception 'ancoras de onboarding_definir_horario_funcionamento sumiram';
  end if;
  v_def := replace(v_def, c_apaga,
    c_apaga
    || E'  delete from app.unit_service_limits\n'
    || E'   where tenant_id = p_tenant_id and configuration_draft_id = v_rascunho;\n');
  v_def := replace(v_def, c_insere,
    c_insere
    || E'\n    -- O atendimento termina ate o salao fechar (sem isto a publicacao\n'
    || E'    -- recusa com LATEST_END_MISSING e o Eddy nao tem como resolver).\n'
    || E'    insert into app.unit_service_limits (tenant_id, configuration_draft_id, weekday, latest_end_time)\n'
    || E'    values (p_tenant_id, v_rascunho, v_dia, v_fecha)\n'
    || E'    on conflict (tenant_id, configuration_draft_id, weekday)\n'
    || E'    do update set latest_end_time = greatest(unit_service_limits.latest_end_time, excluded.latest_end_time);\n');
  execute v_def;
end
$mig$;

insert into app.unit_service_limits (tenant_id, configuration_draft_id, weekday, latest_end_time)
select h.tenant_id, h.configuration_draft_id, h.weekday, max(h.ends_at)
  from app.operating_hours h
  join app.configuration_drafts d on d.id = h.configuration_draft_id and d.status = 'DRAFT'
 where not exists (
   select 1 from app.unit_service_limits l
    where l.tenant_id = h.tenant_id and l.configuration_draft_id = h.configuration_draft_id
      and l.weekday = h.weekday)
 group by h.tenant_id, h.configuration_draft_id, h.weekday
on conflict (tenant_id, configuration_draft_id, weekday) do nothing;
