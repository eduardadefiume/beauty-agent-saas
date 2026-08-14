begin;

create type app.technical_service_family as enum (
  'CUT', 'COLOR', 'BLEACH', 'TREATMENT', 'STRAIGHTENING', 'TEXTURE', 'STYLING', 'OTHER'
);

create type app.technical_step_category as enum (
  'ASSESS', 'PREPARE', 'CLEANSE', 'DRY', 'APPLY', 'PROCESS', 'RINSE', 'NEUTRALIZE', 'TREAT', 'FINISH', 'STYLE', 'OTHER'
);

create type app.technical_requirement_kind as enum (
  'CONSULTATION', 'HAIR_HISTORY', 'STRAND_TEST', 'SENSITIVITY_TEST', 'CONSENT', 'PROFESSIONAL_RELEASE', 'MANUFACTURER_INSTRUCTION'
);

create type app.technical_requirement_severity as enum ('INFO', 'WARNING', 'BLOCKING');

alter table app.service_steps
  add column technical_category app.technical_step_category not null default 'OTHER',
  add column minimum_duration_minutes smallint,
  add column maximum_duration_minutes smallint,
  add column professional_confirmation_required boolean not null default false,
  add column product_record_required boolean not null default false;

-- O backfill altera apenas metadados estruturais já existentes, inclusive em snapshots publicados.
-- A proteção de draft permanece ativa para toda operação normal e é restaurada antes do commit.
alter table app.service_steps disable trigger app_service_steps_draft_open;

update app.service_steps
   set minimum_duration_minutes = duration_minutes,
       maximum_duration_minutes = duration_minutes
 where minimum_duration_minutes is null
    or maximum_duration_minutes is null;

alter table app.service_steps enable trigger app_service_steps_draft_open;

alter table app.service_steps
  alter column minimum_duration_minutes set not null,
  alter column maximum_duration_minutes set not null,
  add constraint service_steps_duration_window_check
    check (
      minimum_duration_minutes > 0
      and maximum_duration_minutes >= minimum_duration_minutes
      and duration_minutes between minimum_duration_minutes and maximum_duration_minutes
    );

create table app.service_technical_profiles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  service_id uuid not null,
  family app.technical_service_family not null default 'OTHER',
  professional_assessment_required boolean not null default false,
  manufacturer_instruction_ref text,
  client_facing_summary text,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, service_id),
  foreign key (tenant_id, configuration_draft_id, service_id)
    references app.services (tenant_id, configuration_draft_id, id) on delete cascade,
  constraint service_technical_profiles_manufacturer_ref_check
    check (manufacturer_instruction_ref is null or length(trim(manufacturer_instruction_ref)) between 3 and 500),
  constraint service_technical_profiles_summary_check
    check (client_facing_summary is null or length(trim(client_facing_summary)) between 3 and 1000)
);

create table app.service_technical_requirements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  service_id uuid not null,
  kind app.technical_requirement_kind not null,
  severity app.technical_requirement_severity not null default 'INFO',
  title text not null,
  instruction text,
  position smallint not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, service_id, position),
  foreign key (tenant_id, configuration_draft_id, service_id)
    references app.services (tenant_id, configuration_draft_id, id) on delete cascade,
  constraint service_technical_requirements_title_check check (length(trim(title)) between 3 and 160),
  constraint service_technical_requirements_instruction_check
    check (instruction is null or length(trim(instruction)) between 3 and 1000)
);

create table app.service_step_product_requirements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  step_id uuid not null,
  product_label text not null,
  manufacturer_instruction_ref text,
  position smallint not null,
  required boolean not null default true,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, configuration_draft_id, id),
  unique (tenant_id, configuration_draft_id, step_id, position),
  foreign key (tenant_id, configuration_draft_id, step_id)
    references app.service_steps (tenant_id, configuration_draft_id, id) on delete cascade,
  constraint service_step_product_requirements_label_check check (length(trim(product_label)) between 2 and 160),
  constraint service_step_product_requirements_ref_check
    check (manufacturer_instruction_ref is null or length(trim(manufacturer_instruction_ref)) between 3 and 500)
);

create index service_technical_profiles_tenant_draft_idx
  on app.service_technical_profiles (tenant_id, configuration_draft_id, service_id);
create index service_technical_requirements_tenant_service_idx
  on app.service_technical_requirements (tenant_id, configuration_draft_id, service_id, position);
create index service_step_product_requirements_tenant_step_idx
  on app.service_step_product_requirements (tenant_id, configuration_draft_id, step_id, position);

create trigger service_technical_profiles_touch_updated_at
before update on app.service_technical_profiles
for each row execute function private.touch_updated_at();
create trigger service_technical_requirements_touch_updated_at
before update on app.service_technical_requirements
for each row execute function private.touch_updated_at();
create trigger service_step_product_requirements_touch_updated_at
before update on app.service_step_product_requirements
for each row execute function private.touch_updated_at();

alter table app.service_technical_profiles enable row level security;
alter table app.service_technical_profiles force row level security;
alter table app.service_technical_requirements enable row level security;
alter table app.service_technical_requirements force row level security;
alter table app.service_step_product_requirements enable row level security;
alter table app.service_step_product_requirements force row level security;

revoke all on app.service_technical_profiles, app.service_technical_requirements, app.service_step_product_requirements
  from public, anon, authenticated;
grant all on app.service_technical_profiles, app.service_technical_requirements, app.service_step_product_requirements
  to service_role;

-- Mantém a implementação anterior como núcleo de substituição transacional.
alter function public.site_replace_configuration(text, text, uuid, integer, jsonb)
  rename to site_replace_configuration_base;

create or replace function private.build_configuration_snapshot(target_draft_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select jsonb_build_object(
    'schemaVersion', 2,
    'tenantId', d.tenant_id,
    'unitId', d.unit_id,
    'sourceDraftId', d.id,
    'sourceRevision', d.revision,
    'depositEnabled', d.deposit_enabled,
    'channelMode', d.channel_mode,
    'finalMessageTemplate', d.final_message_template,
    'cancellationPolicyEnabled', d.cancellation_policy_enabled,
    'cancellationWindowHours', d.cancellation_window_hours,
    'cancellationChargeType', d.cancellation_charge_type,
    'cancellationChargeAmountMinor', d.cancellation_charge_amount_minor,
    'cancellationChargePercentage', d.cancellation_charge_percentage,
    'operatingHours', coalesce((
      select jsonb_agg(to_jsonb(h) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by h.weekday, h.starts_at, h.id)
      from app.operating_hours h where h.tenant_id = d.tenant_id and h.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'serviceLimits', coalesce((
      select jsonb_agg(to_jsonb(l) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by l.weekday, l.id)
      from app.unit_service_limits l where l.tenant_id = d.tenant_id and l.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'clientExceptions', coalesce((
      select jsonb_agg(to_jsonb(ce) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by ce.client_name, ce.weekday, ce.starts_at, ce.id)
      from app.client_schedule_exceptions ce where ce.tenant_id = d.tenant_id and ce.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'skills', coalesce((
      select jsonb_agg((to_jsonb(s) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at') || jsonb_build_object(
        'qualifierOptions', coalesce((
          select jsonb_agg(to_jsonb(o) - 'tenant_id' - 'configuration_draft_id' - 'skill_id' - 'created_at' - 'updated_at' order by o.position)
          from app.skill_qualifier_options o where o.tenant_id = s.tenant_id and o.configuration_draft_id = s.configuration_draft_id and o.skill_id = s.id
        ), '[]'::jsonb)
      ) order by s.name, s.id)
      from app.skills s where s.tenant_id = d.tenant_id and s.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'teamMembers', coalesce((
      select jsonb_agg((to_jsonb(m) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at') || jsonb_build_object(
        'skillIds', coalesce((select jsonb_agg(ms.skill_id order by ms.priority, ms.skill_id) from app.member_skills ms where ms.tenant_id = m.tenant_id and ms.configuration_draft_id = m.configuration_draft_id and ms.member_id = m.id), '[]'::jsonb),
        'skillQualifiers', coalesce((select jsonb_agg(to_jsonb(q) - 'tenant_id' - 'configuration_draft_id' - 'member_id' - 'created_at' order by q.skill_id, q.qualifier_option_id) from app.member_skill_qualifiers q where q.tenant_id = m.tenant_id and q.configuration_draft_id = m.configuration_draft_id and q.member_id = m.id), '[]'::jsonb),
        'availability', coalesce((select jsonb_agg(to_jsonb(a) - 'tenant_id' - 'configuration_draft_id' - 'member_id' - 'created_at' - 'updated_at' order by a.weekday, a.starts_at, a.id) from app.member_availability a where a.tenant_id = m.tenant_id and a.configuration_draft_id = m.configuration_draft_id and a.member_id = m.id), '[]'::jsonb),
        'dynamicShifts', coalesce((select jsonb_agg(to_jsonb(ds) - 'tenant_id' - 'configuration_draft_id' - 'member_id' - 'created_at' - 'updated_at' order by ds.shift_date, ds.starts_at, ds.id) from app.member_dynamic_shifts ds where ds.tenant_id = m.tenant_id and ds.configuration_draft_id = m.configuration_draft_id and ds.member_id = m.id), '[]'::jsonb)
      ) order by m.name, m.id)
      from app.team_members m where m.tenant_id = d.tenant_id and m.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'resourceTypes', coalesce((
      select jsonb_agg((to_jsonb(rt) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at') || jsonb_build_object(
        'resources', coalesce((select jsonb_agg(to_jsonb(r) - 'tenant_id' - 'configuration_draft_id' - 'resource_type_id' - 'created_at' - 'updated_at' order by r.name, r.id) from app.resources r where r.tenant_id = rt.tenant_id and r.configuration_draft_id = rt.configuration_draft_id and r.resource_type_id = rt.id), '[]'::jsonb)
      ) order by rt.name, rt.id)
      from app.resource_types rt where rt.tenant_id = d.tenant_id and rt.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'services', coalesce((
      select jsonb_agg((to_jsonb(svc) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at') || jsonb_build_object(
        'technicalProfile', (
          select (to_jsonb(tp) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at') || jsonb_build_object(
            'requirements', coalesce((select jsonb_agg(to_jsonb(tr) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at' order by tr.position) from app.service_technical_requirements tr where tr.tenant_id = tp.tenant_id and tr.configuration_draft_id = tp.configuration_draft_id and tr.service_id = tp.service_id), '[]'::jsonb)
          ) from app.service_technical_profiles tp where tp.tenant_id = svc.tenant_id and tp.configuration_draft_id = svc.configuration_draft_id and tp.service_id = svc.id
        ),
        'variations', coalesce((select jsonb_agg(to_jsonb(v) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at' order by v.name, v.id) from app.service_variations v where v.tenant_id = svc.tenant_id and v.configuration_draft_id = svc.configuration_draft_id and v.service_id = svc.id), '[]'::jsonb),
        'steps', coalesce((
          select jsonb_agg((to_jsonb(st) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at') || jsonb_build_object(
            'skillRequirements', coalesce((select jsonb_agg((to_jsonb(sr) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'created_at') || jsonb_build_object('qualifier', (select to_jsonb(q) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'skill_id' - 'created_at' from app.service_step_skill_qualifiers q where q.tenant_id = sr.tenant_id and q.configuration_draft_id = sr.configuration_draft_id and q.step_id = sr.step_id and q.skill_id = sr.skill_id limit 1)) order by sr.skill_id) from app.service_step_skill_requirements sr where sr.tenant_id = st.tenant_id and sr.configuration_draft_id = st.configuration_draft_id and sr.step_id = st.id), '[]'::jsonb),
            'resourceRequirements', coalesce((select jsonb_agg(to_jsonb(rr) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'created_at' order by rr.resource_type_id) from app.service_step_resource_requirements rr where rr.tenant_id = st.tenant_id and rr.configuration_draft_id = st.configuration_draft_id and rr.step_id = st.id), '[]'::jsonb),
            'productRequirements', coalesce((select jsonb_agg(to_jsonb(pr) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'created_at' - 'updated_at' order by pr.position) from app.service_step_product_requirements pr where pr.tenant_id = st.tenant_id and pr.configuration_draft_id = st.configuration_draft_id and pr.step_id = st.id), '[]'::jsonb)
          ) order by st.position, st.id) from app.service_steps st where st.tenant_id = svc.tenant_id and st.configuration_draft_id = svc.configuration_draft_id and st.service_id = svc.id
        ), '[]'::jsonb)
      ) order by svc.name, svc.id)
      from app.services svc where svc.tenant_id = d.tenant_id and svc.configuration_draft_id = d.id
    ), '[]'::jsonb)
  ) from app.configuration_drafts d where d.id = target_draft_id
$function$;

create or replace function public.site_replace_configuration(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  expected_revision integer,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  base_result jsonb;
  draft_id_value uuid;
  service_item jsonb;
  requirement_item jsonb;
  step_item jsonb;
  product_item jsonb;
  service_id_value uuid;
  step_id_value uuid;
  requirement_position smallint;
  product_position smallint;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  select public.site_replace_configuration_base(
    target_site_project_id, target_email, target_tenant_id, expected_revision, payload
  ) into base_result;

  select draft.id into draft_id_value
    from app.configuration_drafts draft
   where draft.tenant_id = target_tenant_id and draft.status = 'DRAFT'
   order by draft.revision desc
   limit 1;

  for service_item in select value from jsonb_array_elements(coalesce(payload->'services', '[]'::jsonb))
  loop
    select svc.id into service_id_value
      from app.services svc
     where svc.tenant_id = target_tenant_id
       and svc.configuration_draft_id = draft_id_value
       and svc.name = trim(service_item->>'name');

    if jsonb_typeof(service_item->'technicalProfile') = 'object' then
      insert into app.service_technical_profiles (
        tenant_id, configuration_draft_id, service_id, family, professional_assessment_required,
        manufacturer_instruction_ref, client_facing_summary
      ) values (
        target_tenant_id, draft_id_value, service_id_value,
        coalesce(nullif(service_item #>> '{technicalProfile,family}', ''), 'OTHER')::app.technical_service_family,
        coalesce((service_item #>> '{technicalProfile,professionalAssessmentRequired}')::boolean, false),
        nullif(trim(coalesce(service_item #>> '{technicalProfile,manufacturerInstructionRef}', '')), ''),
        nullif(trim(coalesce(service_item #>> '{technicalProfile,clientFacingSummary}', '')), '')
      );

      requirement_position := 0;
      for requirement_item in select value from jsonb_array_elements(coalesce(service_item #> '{technicalProfile,requirements}', '[]'::jsonb))
      loop
        requirement_position := requirement_position + 1;
        insert into app.service_technical_requirements (
          tenant_id, configuration_draft_id, service_id, kind, severity, title, instruction, position
        ) values (
          target_tenant_id, draft_id_value, service_id_value,
          coalesce(nullif(requirement_item->>'kind', ''), 'CONSULTATION')::app.technical_requirement_kind,
          coalesce(nullif(requirement_item->>'severity', ''), 'INFO')::app.technical_requirement_severity,
          trim(requirement_item->>'title'),
          nullif(trim(coalesce(requirement_item->>'instruction', '')), ''),
          requirement_position
        );
      end loop;
    end if;

    for step_item in select value from jsonb_array_elements(coalesce(service_item->'steps', '[]'::jsonb))
    loop
      select step.id into step_id_value
        from app.service_steps step
       where step.tenant_id = target_tenant_id
         and step.configuration_draft_id = draft_id_value
         and step.service_id = service_id_value
         and step.position = (step_item->>'position')::integer;

      update app.service_steps
         set technical_category = coalesce(nullif(step_item->>'technicalCategory', ''), 'OTHER')::app.technical_step_category,
             minimum_duration_minutes = coalesce(nullif(step_item->>'minimumDurationMinutes', '')::smallint, duration_minutes),
             maximum_duration_minutes = coalesce(nullif(step_item->>'maximumDurationMinutes', '')::smallint, duration_minutes),
             professional_confirmation_required = coalesce((step_item->>'professionalConfirmationRequired')::boolean, false),
             product_record_required = coalesce((step_item->>'productRecordRequired')::boolean, false)
       where id = step_id_value and tenant_id = target_tenant_id and configuration_draft_id = draft_id_value;

      product_position := 0;
      for product_item in select value from jsonb_array_elements(coalesce(step_item->'productRequirements', '[]'::jsonb))
      loop
        product_position := product_position + 1;
        insert into app.service_step_product_requirements (
          tenant_id, configuration_draft_id, step_id, product_label, manufacturer_instruction_ref, position, required
        ) values (
          target_tenant_id, draft_id_value, step_id_value,
          trim(product_item->>'productLabel'),
          nullif(trim(coalesce(product_item->>'manufacturerInstructionRef', '')), ''),
          product_position,
          coalesce((product_item->>'required')::boolean, true)
        );
      end loop;
    end loop;
  end loop;

  return public.site_load_configuration(target_site_project_id, target_email, target_tenant_id);
end;
$function$;

revoke all on function public.site_replace_configuration_base(text, text, uuid, integer, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.site_replace_configuration(text, text, uuid, integer, jsonb)
  from public, anon, authenticated;
grant execute on function public.site_replace_configuration(text, text, uuid, integer, jsonb) to service_role;

comment on table app.service_technical_profiles is
  'Perfil técnico versionado por serviço. Instruções de fabricante são referência obrigatória do estabelecimento, não protocolo criado por IA.';
comment on table app.service_technical_requirements is
  'Pré-requisitos e alertas técnicos configurados pelo estabelecimento; BLOCKING exige escalonamento antes da agenda.';
comment on table app.service_step_product_requirements is
  'Produtos esperados por etapa. Registro de lote na execução será implementado no módulo de atendimento.';

commit;
