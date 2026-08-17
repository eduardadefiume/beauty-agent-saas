-- Move o canal WhatsApp do tenant salao-do-william para piloto-eduarda.
--
-- Motivo (decisao da proprietaria, opcao A): o piloto estava partido em dois
-- tenants. O canal WhatsApp vivia em salao-do-william, que nao tem nenhuma
-- versao de configuracao publicada -- sem servicos, sem horarios. Toda a
-- configuracao publicada e a conexao de Google Agenda estao em piloto-eduarda,
-- que por sua vez nao tinha canal. Mesmo que uma mensagem chegasse, cairia num
-- tenant sem catalogo para o agente consultar.
--
-- O B1 (provar que uma mensagem real chega em app.inbox_events) e um teste de
-- encanamento e nao precisa do catalogo real do William. Depois de provado o
-- caminho, o tenant dele pode ser montado com calma.
--
-- Tecnica: as FKs (tenant_id, connection_id) -> channel_connections(tenant_id,
-- id) NAO sao deferiveis, entao nao e possivel apenas atualizar o tenant_id do
-- pai. Os filhos sao removidos, o pai e movido e os filhos sao recriados com os
-- mesmos ids, na mesma transacao.
--
-- Seguro nesta janela: app.inbox_events esta vazia (nenhum webhook jamais
-- chegou), entao nao ha evento historico para reassociar. A migracao aborta
-- explicitamente se encontrar eventos, para nao orfanar historico caso seja
-- reaplicada em outro ambiente.
--
-- Verificado apos aplicar: piloto-eduarda passou a concentrar canal WhatsApp,
-- numero autorizado, calendario ativo e versao publicada; os outros dois
-- tenants ficaram zerados.

do $$
declare
  v_conn uuid := 'a3f4246e-f8ee-4be7-8373-2ac9a94500c3';
  v_old_tenant uuid := 'b6f65c60-5ed8-4e9a-a196-ab73b43213d4';
  v_new_tenant uuid := '4b2a8e37-1716-41c4-9201-eefce890638d';
  v_eventos integer;
begin
  select count(*) into v_eventos from app.inbox_events where connection_id = v_conn;
  if v_eventos > 0 then
    raise exception 'ABORTADO: % evento(s) em inbox_events para esta conexao. Reassociar antes de mover.', v_eventos;
  end if;

  if not exists (select 1 from app.channel_connections where id = v_conn and tenant_id = v_old_tenant) then
    raise notice 'Canal nao esta no tenant de origem; nada a fazer.';
    return;
  end if;

  create temp table _allowlist_backup on commit drop as
    select * from app.channel_allowlist where connection_id = v_conn;

  delete from app.channel_allowlist where connection_id = v_conn;

  update app.channel_connections
     set tenant_id = v_new_tenant, updated_at = statement_timestamp()
   where id = v_conn;

  insert into app.channel_allowlist (
    id, tenant_id, connection_id, normalized_contact, status, expires_at, created_at, updated_at
  )
  select id, v_new_tenant, connection_id, normalized_contact, status, expires_at, created_at, statement_timestamp()
    from _allowlist_backup;
end $$;
