insert into app.site_identities (tenant_id, site_project_id, email_normalized, role, status)
select t.id, 'owner-console-v1', 'agente@sistema.interno', 'OPERATOR', 'ACTIVE'
  from app.tenants t
 where not exists (
   select 1 from app.site_identities s
    where s.tenant_id = t.id
      and s.site_project_id = 'owner-console-v1'
      and s.email_normalized = 'agente@sistema.interno'
 );

comment on table app.site_identities is
  'Quem pode agir em nome de qual tenant, por projeto de site. Inclui a identidade de servico agente@sistema.interno, que nao tem login e so vale acompanhada do token de worker.';