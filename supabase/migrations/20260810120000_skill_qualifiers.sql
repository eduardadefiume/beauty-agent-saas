begin;

-- Competências hierárquicas (qualificadores). Sem isso, "tem a competência
-- Coloração" é tratado como "sabe fazer QUALQUER coloração", o que é falso
-- na prática (nem toda colorista faz vermelho; Gloss Express muda o tempo
-- de ação conforme o tom). Uma skill pode opcionalmente ter um
-- qualificador — uma pergunta de escolha (ex.: "Tom") com opções definidas
-- pela própria dona do negócio, e "outro" com texto livre quando permitido.

alter table app.skills
  add column qualifier_label text
    check (qualifier_label is null or length(trim(qualifier_label)) between 1 and 80),
  add column qualifier_allow_custom boolean not null default false;

create table app.skill_qualifier_options (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  skill_id uuid not null,
  label text not null check (length(trim(label)) between 1 and 120),
  position integer not null check (position > 0),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, skill_id, position),
  unique (tenant_id, configuration_draft_id, skill_id, label),
  foreign key (tenant_id, configuration_draft_id, skill_id)
    references app.skills(tenant_id, configuration_draft_id, id) on delete cascade
);

-- Quais opções do qualificador cada pessoa da equipe cobre naquela
-- competência. Uma linha por opção coberta (uma pessoa pode cobrir várias:
-- ex. Coloração castanho/preto E vermelho). qualifier_option_id nulo +
-- custom_value preenchido = cobertura livre ("outro"), só quando a skill
-- permite isso.
create table app.member_skill_qualifiers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  member_id uuid not null,
  skill_id uuid not null,
  qualifier_option_id uuid,
  custom_value text check (custom_value is null or length(trim(custom_value)) between 1 and 160),
  created_at timestamptz not null default statement_timestamp(),
  check (
    (qualifier_option_id is not null and custom_value is null)
    or (qualifier_option_id is null and custom_value is not null)
  ),
  unique (tenant_id, configuration_draft_id, member_id, skill_id, qualifier_option_id),
  foreign key (tenant_id, configuration_draft_id, member_id, skill_id)
    references app.member_skills(tenant_id, configuration_draft_id, member_id, skill_id) on delete cascade,
  foreign key (tenant_id, configuration_draft_id, qualifier_option_id)
    references app.skill_qualifier_options(tenant_id, configuration_draft_id, id) on delete cascade
);

-- Qual opção do qualificador uma etapa de serviço exige (ex.: a etapa
-- "Coloração vermelha" exige skill Coloração + opção Vermelho). No máximo
-- uma linha por (etapa, skill) na prática — é isso que a checagem de
-- prontidão abaixo cobra quando a skill tem qualificador.
create table app.service_step_skill_qualifiers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  step_id uuid not null,
  skill_id uuid not null,
  qualifier_option_id uuid,
  custom_value text check (custom_value is null or length(trim(custom_value)) between 1 and 160),
  created_at timestamptz not null default statement_timestamp(),
  check (
    (qualifier_option_id is not null and custom_value is null)
    or (qualifier_option_id is null and custom_value is not null)
  ),
  unique (tenant_id, configuration_draft_id, step_id, skill_id, qualifier_option_id),
  foreign key (tenant_id, configuration_draft_id, step_id, skill_id)
    references app.service_step_skill_requirements(tenant_id, configuration_draft_id, step_id, skill_id) on delete cascade,
  foreign key (tenant_id, configuration_draft_id, qualifier_option_id)
    references app.skill_qualifier_options(tenant_id, configuration_draft_id, id) on delete cascade
);

create index skill_qualifier_options_skill_idx on app.skill_qualifier_options (tenant_id, configuration_draft_id, skill_id);
create index member_skill_qualifiers_lookup_idx on app.member_skill_qualifiers (tenant_id, configuration_draft_id, member_id, skill_id);
create index step_skill_qualifiers_lookup_idx on app.service_step_skill_qualifiers (tenant_id, configuration_draft_id, step_id, skill_id);

-- RLS: mesma política das demais tabelas de rascunho (leitura para membros
-- do tenant; escrita real só via public.site_replace_configuration, que
-- roda como SECURITY DEFINER e não depende destes grants).
alter table app.skill_qualifier_options enable row level security;
alter table app.member_skill_qualifiers enable row level security;
alter table app.service_step_skill_qualifiers enable row level security;

create policy skill_qualifier_options_select_member on app.skill_qualifier_options
  for select to authenticated using (private.has_tenant_role(tenant_id));
create policy member_skill_qualifiers_select_member on app.member_skill_qualifiers
  for select to authenticated using (private.has_tenant_role(tenant_id));
create policy service_step_skill_qualifiers_select_member on app.service_step_skill_qualifiers
  for select to authenticated using (private.has_tenant_role(tenant_id));

grant select, insert, update, delete on table app.skill_qualifier_options to authenticated, service_role;
grant select, insert, update, delete on table app.member_skill_qualifiers to authenticated, service_role;
grant select, insert, update, delete on table app.service_step_skill_qualifiers to authenticated, service_role;

create trigger skill_qualifier_options_touch_updated_at
before update on app.skill_qualifier_options
for each row execute function private.touch_updated_at();

commit;
