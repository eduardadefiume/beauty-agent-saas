-- Publicação do catálogo do piloto.
--
-- Repete passo a passo o que api.publish_configuration faz. Não dá para chamar
-- a função em si daqui: ela autoriza por private.has_tenant_role(auth.uid()) e
-- uma migração roda sem usuário autenticado. O que muda é só a autorização e o
-- ator do log -- a sequência (snapshot, hash, versão, rascunho PUBLISHED,
-- unidade apontando para a nova versão, auditoria) é idêntica.
--
-- Sai sem fazer nada se o rascunho já estiver publicado, então rodar duas vezes
-- não cria duas versões.
do $$
declare
  v_draft   app.configuration_drafts%rowtype;
  v_proxima integer;
  v_snapshot jsonb;
  v_hash    text;
  v_versao  uuid;
begin
  select d.* into v_draft
    from app.configuration_drafts d
   where d.id = '00ba4dc0-4367-4296-a8ce-25f51212cb81'
   for update;

  if v_draft.status <> 'DRAFT' then
    raise notice 'rascunho ja publicado, nada a fazer';
    return;
  end if;

  if exists (select 1 from private.configuration_readiness(v_draft.id)) then
    raise exception 'CONFIGURATION_NOT_READY';
  end if;

  select coalesce(max(v.version_number), 0) + 1 into v_proxima
    from app.configuration_versions v
   where v.tenant_id = v_draft.tenant_id and v.unit_id = v_draft.unit_id;

  v_snapshot := private.build_configuration_snapshot(v_draft.id);
  v_hash := encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex');

  insert into app.configuration_versions (
    tenant_id, unit_id, source_draft_id, version_number, snapshot, snapshot_hash, published_by
  ) values (
    v_draft.tenant_id, v_draft.unit_id, v_draft.id, v_proxima, v_snapshot, v_hash, null
  ) returning id into v_versao;

  update app.configuration_drafts
     set status = 'PUBLISHED', updated_at = statement_timestamp()
   where id = v_draft.id;

  update app.units
     set active_configuration_version_id = v_versao, updated_at = statement_timestamp()
   where id = v_draft.unit_id and tenant_id = v_draft.tenant_id;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id,
    configuration_version_id, correlation_id, result, metadata_minimized
  ) values (
    v_draft.tenant_id, 'SYSTEM', null, 'CONFIGURATION_PUBLISHED', 'configuration_version', v_versao,
    v_versao, 'migracao-catalogo-salao-piloto', 'SUCCESS',
    jsonb_build_object('versionNumber', v_proxima, 'snapshotHash', v_hash,
                       'origem', 'migracao 20260821120000_catalogo_salao_piloto')
  );

  raise notice 'publicado: versao % (%)', v_proxima, v_versao;
end $$;
