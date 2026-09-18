begin;

create or replace function public.can_access_tenant(target_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_tenant_role(target_tenant_id);
$$;

revoke all on function public.can_access_tenant(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.can_access_tenant(uuid)
  to authenticated, service_role;

comment on function public.can_access_tenant(uuid) is
  'Narrow authenticated guard for integration-edge tenant authorization.';

commit;
