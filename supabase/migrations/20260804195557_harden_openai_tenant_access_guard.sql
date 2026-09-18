begin;

create or replace function public.can_access_tenant(target_tenant_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1
      from app.tenant_memberships membership
     where membership.tenant_id = target_tenant_id
       and membership.profile_id = (select auth.uid())
       and membership.status = 'ACTIVE'
  );
$$;

commit;
