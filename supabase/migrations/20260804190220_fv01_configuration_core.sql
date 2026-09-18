begin;

create type app.configuration_status as enum ('DRAFT', 'PUBLISHED', 'ARCHIVED');
create type app.availability_mode as enum ('FIXED', 'HYBRID', 'DYNAMIC');
create type app.service_kind as enum ('SIMPLE', 'COMPOSITE');
create type app.step_kind as enum ('ACTIVE', 'PASSIVE');

create table app.configuration_drafts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  revision integer not null default 1 check (revision > 0),
  status app.configuration_status not null default 'DRAFT',
  deposit_enabled boolean not null default false check (deposit_enabled = false),
  channel_mode text not null default 'RESTRICTED' check (channel_mode = 'RESTRICTED'),
  final_message_template text,
  created_by uuid references app.profiles(id) on delete set null,
  updated_by uuid references app.profiles(id) on delete set null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, id),
  unique (tenant_id, unit_id, revision),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete restrict
);

create unique index configuration_drafts_one_open_per_unit
  on app.configuration_drafts (tenant_id, unit_id)
  where status = 'DRAFT';

create table app.operating_hours (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  weekday smallint not null check (weekday between 0 and 6),
  starts_at time not null,
  ends_at time not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (starts_at < ends_at),
  unique (tenant_id, configuration_draft_id, weekday, starts_at, ends_at),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade
);

create table app.unit_service_limits (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  weekday smallint not null check (weekday between 0 and 6),
  latest_end_time time not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, weekday),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade
);

create table app.skills (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 120),
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, name),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade
);

create table app.team_members (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 160),
  member_type text not null default 'PROFESSIONAL'
    check (member_type in ('PROFESSIONAL', 'ASSISTANT')),
  availability_mode app.availability_mode not null default 'FIXED',
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade
);

create table app.member_skills (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  member_id uuid not null,
  skill_id uuid not null,
  priority smallint not null default 100 check (priority > 0),
  created_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, member_id, skill_id),
  foreign key (tenant_id, configuration_draft_id, member_id)
    references app.team_members(tenant_id, configuration_draft_id, id) on delete cascade,
  foreign key (tenant_id, configuration_draft_id, skill_id)
    references app.skills(tenant_id, configuration_draft_id, id) on delete restrict
);

create table app.member_availability (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  member_id uuid not null,
  weekday smallint not null check (weekday between 0 and 6),
  starts_at time not null,
  ends_at time not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (starts_at < ends_at),
  unique (tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at),
  foreign key (tenant_id, configuration_draft_id, member_id)
    references app.team_members(tenant_id, configuration_draft_id, id) on delete cascade
);

create table app.resource_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 120),
  description text,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, name),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade
);

create table app.resources (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  resource_type_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 120),
  capacity integer not null default 1 check (capacity > 0),
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, name),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade,
  foreign key (tenant_id, configuration_draft_id, resource_type_id)
    references app.resource_types(tenant_id, configuration_draft_id, id) on delete restrict
);

create table app.services (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 160),
  description text,
  kind app.service_kind not null default 'SIMPLE',
  base_price_minor integer check (base_price_minor is null or base_price_minor >= 0),
  currency char(3) not null default 'BRL' check (currency ~ '^[A-Z]{3}$'),
  bookable boolean not null default true,
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, name),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade
);

create table app.service_variations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  service_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 160),
  classification_values jsonb not null default '{}'::jsonb,
  price_minor integer check (price_minor is null or price_minor >= 0),
  status app.record_status not null default 'ACTIVE',
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, service_id, name),
  foreign key (tenant_id, configuration_draft_id, service_id)
    references app.services(tenant_id, configuration_draft_id, id) on delete cascade
);

create table app.service_steps (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  service_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 160),
  position integer not null check (position > 0),
  duration_minutes integer not null check (duration_minutes > 0),
  kind app.step_kind not null default 'ACTIVE',
  customer_presence_required boolean not null default true,
  releases_member boolean not null default false,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, service_id, position),
  foreign key (tenant_id, configuration_draft_id, service_id)
    references app.services(tenant_id, configuration_draft_id, id) on delete cascade,
  check (kind = 'PASSIVE' or releases_member = false)
);

create table app.service_step_skill_requirements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  step_id uuid not null,
  skill_id uuid not null,
  quantity integer not null default 1 check (quantity > 0),
  created_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, step_id, skill_id),
  foreign key (tenant_id, configuration_draft_id, step_id)
    references app.service_steps(tenant_id, configuration_draft_id, id) on delete cascade,
  foreign key (tenant_id, configuration_draft_id, skill_id)
    references app.skills(tenant_id, configuration_draft_id, id) on delete restrict
);

create table app.service_step_resource_requirements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  step_id uuid not null,
  resource_type_id uuid not null,
  quantity integer not null default 1 check (quantity > 0),
  retain_until_service_end boolean not null default false,
  created_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, step_id, resource_type_id),
  foreign key (tenant_id, configuration_draft_id, step_id)
    references app.service_steps(tenant_id, configuration_draft_id, id) on delete cascade,
  foreign key (tenant_id, configuration_draft_id, resource_type_id)
    references app.resource_types(tenant_id, configuration_draft_id, id) on delete restrict
);

create table app.configuration_versions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  source_draft_id uuid not null,
  version_number integer not null check (version_number > 0),
  snapshot jsonb not null,
  snapshot_hash text not null check (snapshot_hash ~ '^[a-f0-9]{64}$'),
  published_by uuid references app.profiles(id) on delete set null,
  published_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, id),
  unique (tenant_id, unit_id, version_number),
  unique (tenant_id, unit_id, snapshot_hash),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete restrict,
  foreign key (tenant_id, source_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete restrict
);

alter table app.units
  add constraint units_active_configuration_version_fk
  foreign key (tenant_id, active_configuration_version_id)
  references app.configuration_versions(tenant_id, id)
  on delete restrict;

create index configuration_drafts_unit_idx on app.configuration_drafts (tenant_id, unit_id, status);
create index operating_hours_draft_idx on app.operating_hours (tenant_id, configuration_draft_id, weekday);
create index member_availability_lookup_idx on app.member_availability (tenant_id, configuration_draft_id, weekday, member_id);
create index resources_type_idx on app.resources (tenant_id, configuration_draft_id, resource_type_id) where status = 'ACTIVE';
create index services_bookable_idx on app.services (tenant_id, configuration_draft_id) where status = 'ACTIVE' and bookable;
create index service_steps_order_idx on app.service_steps (tenant_id, configuration_draft_id, service_id, position);
create index configuration_versions_unit_idx on app.configuration_versions (tenant_id, unit_id, version_number desc);

create or replace function private.prevent_configuration_version_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'Published configuration versions are immutable';
end;
$$;

revoke all on function private.prevent_configuration_version_mutation() from public, anon, authenticated, service_role;

create trigger configuration_versions_immutable
before update or delete on app.configuration_versions
for each row execute function private.prevent_configuration_version_mutation();

do $$
declare
  target_table regclass;
  mutable_tables regclass[] := array[
    'app.configuration_drafts'::regclass,
    'app.operating_hours'::regclass,
    'app.unit_service_limits'::regclass,
    'app.skills'::regclass,
    'app.team_members'::regclass,
    'app.member_skills'::regclass,
    'app.member_availability'::regclass,
    'app.resource_types'::regclass,
    'app.resources'::regclass,
    'app.services'::regclass,
    'app.service_variations'::regclass,
    'app.service_steps'::regclass,
    'app.service_step_skill_requirements'::regclass,
    'app.service_step_resource_requirements'::regclass
  ];
begin
  foreach target_table in array mutable_tables loop
    execute format('alter table %s enable row level security', target_table);
    execute format(
      'create policy %I on %s for select to authenticated using (private.has_tenant_role(tenant_id))',
      replace(target_table::text, '.', '_') || '_select_member',
      target_table
    );
    execute format(
      'create policy %I on %s for insert to authenticated with check (private.has_tenant_role(tenant_id, array[''OWNER''::app.tenant_role, ''ADMIN''::app.tenant_role]))',
      replace(target_table::text, '.', '_') || '_insert_admin',
      target_table
    );
    execute format(
      'create policy %I on %s for update to authenticated using (private.has_tenant_role(tenant_id, array[''OWNER''::app.tenant_role, ''ADMIN''::app.tenant_role])) with check (private.has_tenant_role(tenant_id, array[''OWNER''::app.tenant_role, ''ADMIN''::app.tenant_role]))',
      replace(target_table::text, '.', '_') || '_update_admin',
      target_table
    );
    execute format(
      'create policy %I on %s for delete to authenticated using (private.has_tenant_role(tenant_id, array[''OWNER''::app.tenant_role, ''ADMIN''::app.tenant_role]))',
      replace(target_table::text, '.', '_') || '_delete_admin',
      target_table
    );
  end loop;
end;
$$;

alter table app.configuration_versions enable row level security;
create policy configuration_versions_select_member
  on app.configuration_versions
  for select to authenticated
  using (private.has_tenant_role(tenant_id));

do $$
declare
  target_table regclass;
  mutable_tables regclass[] := array[
    'app.configuration_drafts'::regclass,
    'app.operating_hours'::regclass,
    'app.unit_service_limits'::regclass,
    'app.skills'::regclass,
    'app.team_members'::regclass,
    'app.member_skills'::regclass,
    'app.member_availability'::regclass,
    'app.resource_types'::regclass,
    'app.resources'::regclass,
    'app.services'::regclass,
    'app.service_variations'::regclass,
    'app.service_steps'::regclass,
    'app.service_step_skill_requirements'::regclass,
    'app.service_step_resource_requirements'::regclass
  ];
begin
  foreach target_table in array mutable_tables loop
    execute format('grant select, insert, update, delete on table %s to authenticated', target_table);
    execute format('grant select, insert, update, delete on table %s to service_role', target_table);
  end loop;
end;
$$;

grant select on table app.configuration_versions to authenticated;
grant select, insert on table app.configuration_versions to service_role;

do $$
declare
  target_table regclass;
  mutable_tables regclass[] := array[
    'app.configuration_drafts'::regclass,
    'app.operating_hours'::regclass,
    'app.unit_service_limits'::regclass,
    'app.skills'::regclass,
    'app.team_members'::regclass,
    'app.member_skills'::regclass,
    'app.member_availability'::regclass,
    'app.resource_types'::regclass,
    'app.resources'::regclass,
    'app.services'::regclass,
    'app.service_variations'::regclass,
    'app.service_steps'::regclass,
    'app.service_step_skill_requirements'::regclass,
    'app.service_step_resource_requirements'::regclass
  ];
begin
  foreach target_table in array mutable_tables loop
    execute format(
      'create trigger %I before update on %s for each row execute function private.touch_updated_at()',
      replace(target_table::text, '.', '_') || '_touch_updated_at',
      target_table
    );
  end loop;
end;
$$;

commit;
