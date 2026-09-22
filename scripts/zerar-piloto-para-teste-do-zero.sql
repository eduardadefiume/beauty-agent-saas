-- ZERAR O TENANT PILOTO PARA O TESTE DE DONA NOVA.
--
-- 22/09/2026. NAO e migration: isso e dado, nao esquema. Nao pode entrar em
-- supabase/migrations -- rodaria de novo em qualquer ambiente novo e apagaria
-- um salao de verdade. Rodar a mao, uma vez.
--
-- ANTES DE RODAR, confira que o backup existe:
--   select count(*) from backup_zero_20260922.services;   -- tem que dar 101
--
-- O QUE FICA DE PE, e por que: sem esses seis o salao vira inalcancavel --
-- nao tem numero, nao tem como entrar, e o Eddy nao reconhece a dona.
--   tenants, units .............. o salao e a unidade existirem
--   channel_connections ......... o NUMERO e o token da Meta
--   channel_allowlist ........... quem pode escrever
--   site_identities ............. o seu login no painel
--   owner_whatsapp .............. o Eddy saber que quem escreve e a dona
--   agent_automation ............ o interruptor (fica como esta: desligado)
--
-- TUDO o mais do tenant vai embora: 101 servicos, 293 contatos, 286 visitas,
-- 553 procedimentos, 47 politicas, o historico das conversas, os rascunhos e
-- as versoes publicadas.

begin;

do $$
declare
  v_piloto uuid := '4b2a8e37-1716-41c4-9201-eefce890638d';
  manter text[] := array['tenants','units','channel_connections','channel_allowlist',
                         'site_identities','owner_whatsapp','agent_automation'];
  r record; passada int; presas int := 0;
begin
  -- A unidade aponta para a versao publicada com FK RESTRICT: enquanto
  -- apontar, configuration_versions nao sai do lugar.
  update app.units set active_configuration_version_id = null where tenant_id = v_piloto;

  -- Varre em passadas ate nao sobrar nada, para nao ter que adivinhar a ordem
  -- das chaves estrangeiras: quem dita a ordem e o banco.
  for passada in 1..15 loop
    presas := 0;
    for r in
      select c.table_name
        from information_schema.columns c
        join information_schema.tables t
          on t.table_schema = 'app' and t.table_name = c.table_name
         and t.table_type = 'BASE TABLE'
       where c.table_schema = 'app' and c.column_name = 'tenant_id'
         and not (c.table_name = any(manter))
    loop
      begin
        execute format('delete from app.%I where tenant_id = %L', r.table_name, v_piloto);
      exception when foreign_key_violation then
        presas := presas + 1;
      end;
    end loop;
    exit when presas = 0;
  end loop;

  if presas > 0 then
    raise exception 'ABORTADO: % tabelas nao esvaziaram -- nada foi apagado', presas;
  end if;
end $$;

-- O salao renasce com o mesmo vocabulario que um salao novo recebe.
select app.seed_color_model('4b2a8e37-1716-41c4-9201-eefce890638d');
select app.seed_tenant_knowledge('4b2a8e37-1716-41c4-9201-eefce890638d');

-- E com o rascunho inicial, senao nao ha por onde comecar.
insert into app.configuration_drafts (tenant_id, unit_id, revision, status)
select u.tenant_id, u.id, 1, 'DRAFT'
from app.units u
where u.tenant_id = '4b2a8e37-1716-41c4-9201-eefce890638d';

-- CONFIRA ANTES DE COMMITAR. Tem que dar tudo zero, menos o que foi mantido.
select 'servicos' as o, count(*) from app.services where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select 'contatos', count(*) from app.crm_contacts where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select 'mensagens', count(*) from app.crm_messages where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select 'politicas', count(*) from app.agent_policies where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select 'equipe', count(*) from app.team_members where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select '-- MANTIDO: numero', count(*) from app.channel_connections where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select '-- MANTIDO: dona', count(*) from app.owner_whatsapp where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select '-- MANTIDO: login', count(*) from app.site_identities where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d'
union all select '-- NOVO: rascunho', count(*) from app.configuration_drafts where tenant_id='4b2a8e37-1716-41c4-9201-eefce890638d';

-- Se a lista acima estiver certa:   commit;
-- Se qualquer coisa parecer errada:  rollback;
commit;
