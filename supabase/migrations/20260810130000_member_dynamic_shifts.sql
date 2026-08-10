begin;

-- Disponibilidade Dinâmica por data específica (não recorrente por dia da
-- semana como FIXED/HYBRID) — ex.: "Duda trabalha sábado 10/08 das 7h às
-- 18h", mas não todo sábado. É essa tabela que o calendário do módulo
-- Equipe grava, e é dela que o motor de agenda lê a disponibilidade de
-- gente em modo Dinâmico (hoje esses membros eram simplesmente excluídos
-- da busca, por não existir fonte real de "quando ela trabalha").
--
-- Quando a integração com Google/Outlook existir (FV-04, depende da Duda
-- criar a conta OAuth), o plano é o sync preencher esta MESMA tabela em vez
-- de duplicar o modelo — hoje o preenchimento é manual, direto no
-- calendário do configurador.

create table app.member_dynamic_shifts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  member_id uuid not null,
  shift_date date not null,
  starts_at time not null,
  ends_at time not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (starts_at < ends_at),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, member_id, shift_date, starts_at, ends_at),
  foreign key (tenant_id, configuration_draft_id, member_id)
    references app.team_members(tenant_id, configuration_draft_id, id) on delete cascade
);

create index member_dynamic_shifts_lookup_idx
  on app.member_dynamic_shifts (tenant_id, configuration_draft_id, member_id, shift_date);

alter table app.member_dynamic_shifts enable row level security;
create policy member_dynamic_shifts_select_member on app.member_dynamic_shifts
  for select to authenticated using (private.has_tenant_role(tenant_id));

grant select, insert, update, delete on table app.member_dynamic_shifts to authenticated, service_role;

create trigger member_dynamic_shifts_touch_updated_at
before update on app.member_dynamic_shifts
for each row execute function private.touch_updated_at();

commit;
