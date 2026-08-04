begin;

create index configuration_drafts_created_by_idx
  on app.configuration_drafts (created_by)
  where created_by is not null;

create index configuration_drafts_updated_by_idx
  on app.configuration_drafts (updated_by)
  where updated_by is not null;

create index configuration_versions_published_by_idx
  on app.configuration_versions (published_by)
  where published_by is not null;

create index configuration_versions_source_draft_idx
  on app.configuration_versions (tenant_id, source_draft_id);

create index member_skills_skill_idx
  on app.member_skills (tenant_id, configuration_draft_id, skill_id);

create index step_resource_requirements_type_idx
  on app.service_step_resource_requirements (
    tenant_id,
    configuration_draft_id,
    resource_type_id
  );

create index step_skill_requirements_skill_idx
  on app.service_step_skill_requirements (
    tenant_id,
    configuration_draft_id,
    skill_id
  );

create index units_active_configuration_version_idx
  on app.units (tenant_id, active_configuration_version_id)
  where active_configuration_version_id is not null;

commit;
