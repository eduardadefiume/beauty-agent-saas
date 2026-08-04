begin;

create schema if not exists app;
create schema if not exists private;

revoke all on schema app from public, anon, authenticated;
revoke all on schema private from public, anon, authenticated;

create type app.record_status as enum ('ACTIVE', 'INACTIVE');
create type app.tenant_role as enum ('OWNER', 'ADMIN', 'OPERATOR', 'VIEWER');
create type app.audit_result as enum ('SUCCESS', 'DENIED', 'FAILED');

create table app.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (length(trim(display_name)) between 1 and 120),
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp()
);

create table app.tenants (
  id uuid primary key default gen_random_uuid(),
  legal_name text,
  display_name text not null check (length(trim(display_name)) between 1 and 160),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  segment_hint text,
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp()
);

create table app.units (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants (id) on delete restrict,
  name text not null check (length(trim(name)) between 1 and 160),
  timezone text not null check (length(trim(timezone)) between 1 and 100),
  address_json jsonb not null default '{}'::jsonb,
  active_configuration_version_id uuid,
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint units_tenant_id_id_unique unique (tenant_id, id)
);

create table app.tenant_memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants (id) on delete cascade,
  profile_id uuid not null references app.profiles (id) on delete cascade,
  role app.tenant_role not null,
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint tenant_memberships_profile_unique unique (tenant_id, profile_id),
  constraint tenant_memberships_tenant_id_id_unique unique (tenant_id, id)
);

create table app.audit_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants (id) on delete restrict,
  actor_type text not null check (actor_type in ('USER', 'SYSTEM', 'WORKER')),
  actor_id uuid,
  action text not null check (length(trim(action)) between 1 and 160),
  entity_type text not null check (length(trim(entity_type)) between 1 and 120),
  entity_id uuid,
  configuration_version_id uuid,
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  result app.audit_result not null,
  metadata_minimized jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  constraint audit_logs_tenant_id_id_unique unique (tenant_id, id)
);

create index tenant_memberships_profile_active_idx
  on app.tenant_memberships (profile_id, tenant_id)
  where status = 'ACTIVE';

create index units_tenant_status_idx on app.units (tenant_id, status);
create index audit_logs_tenant_created_idx on app.audit_logs (tenant_id, created_at desc);
create index audit_logs_correlation_idx on app.audit_logs (correlation_id);

create or replace function private.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = statement_timestamp();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
before update on app.profiles
for each row execute function private.touch_updated_at();

create trigger tenants_touch_updated_at
before update on app.tenants
for each row execute function private.touch_updated_at();

create trigger units_touch_updated_at
before update on app.units
for each row execute function private.touch_updated_at();

create trigger tenant_memberships_touch_updated_at
before update on app.tenant_memberships
for each row execute function private.touch_updated_at();

create or replace function private.has_tenant_role(
  target_tenant_id uuid,
  allowed_roles app.tenant_role[] default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and exists (
      select 1
      from app.tenant_memberships membership
      where membership.tenant_id = target_tenant_id
        and membership.profile_id = (select auth.uid())
        and membership.status = 'ACTIVE'
        and (allowed_roles is null or membership.role = any(allowed_roles))
    );
$$;

revoke all on function private.touch_updated_at() from public, anon, authenticated;
revoke all on function private.has_tenant_role(uuid, app.tenant_role[]) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.has_tenant_role(uuid, app.tenant_role[]) to authenticated;

alter table app.profiles enable row level security;
alter table app.profiles force row level security;
alter table app.tenants enable row level security;
alter table app.tenants force row level security;
alter table app.units enable row level security;
alter table app.units force row level security;
alter table app.tenant_memberships enable row level security;
alter table app.tenant_memberships force row level security;
alter table app.audit_logs enable row level security;
alter table app.audit_logs force row level security;

create policy profiles_select_self
on app.profiles for select
to authenticated
using (id = (select auth.uid()));

create policy profiles_insert_self
on app.profiles for insert
to authenticated
with check (id = (select auth.uid()));

create policy profiles_update_self
on app.profiles for update
to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy tenants_select_member
on app.tenants for select
to authenticated
using (private.has_tenant_role(id));

create policy units_select_member
on app.units for select
to authenticated
using (private.has_tenant_role(tenant_id));

create policy units_insert_admin
on app.units for insert
to authenticated
with check (private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[]));

create policy units_update_admin
on app.units for update
to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[]))
with check (private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[]));

create policy units_delete_owner
on app.units for delete
to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER']::app.tenant_role[]));

create policy memberships_select_self_or_admin
on app.tenant_memberships for select
to authenticated
using (
  profile_id = (select auth.uid())
  or private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[])
);

create policy memberships_insert_owner
on app.tenant_memberships for insert
to authenticated
with check (private.has_tenant_role(tenant_id, array['OWNER']::app.tenant_role[]));

create policy memberships_update_owner
on app.tenant_memberships for update
to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER']::app.tenant_role[]))
with check (private.has_tenant_role(tenant_id, array['OWNER']::app.tenant_role[]));

create policy memberships_delete_owner
on app.tenant_memberships for delete
to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER']::app.tenant_role[]));

create policy audit_logs_select_admin
on app.audit_logs for select
to authenticated
using (private.has_tenant_role(tenant_id, array['OWNER', 'ADMIN']::app.tenant_role[]));

revoke all on all tables in schema app from public, anon, authenticated;
revoke all on all sequences in schema app from public, anon, authenticated;
grant usage on schema app to authenticated;
grant select, insert, update on app.profiles to authenticated;
grant select on app.tenants to authenticated;
grant select, insert, update, delete on app.units to authenticated;
grant select, insert, update, delete on app.tenant_memberships to authenticated;
grant select on app.audit_logs to authenticated;

comment on schema app is 'Business data. Not exposed directly through the Data API.';
comment on schema private is 'Internal authorization and database utilities. Never expose through the Data API.';
comment on table app.audit_logs is 'Append-only audit trail. Authenticated users have no INSERT, UPDATE, or DELETE policy.';
comment on column app.units.active_configuration_version_id is
  'Foreign key is added with the configuration version migration to avoid a circular creation dependency.';

commit;
