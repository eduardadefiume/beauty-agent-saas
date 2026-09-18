begin;

-- site_start_new_draft não estava levando os campos de política de
-- cancelamento (criados depois dela) para o rascunho clonado. Corrigido.
create or replace function public.site_start_new_draft(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_correlation_id text
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  source_draft app.configuration_drafts%rowtype;
  existing_open_draft app.configuration_drafts%rowtype;
  new_draft_id uuid;
  next_revision integer;
  skill_map jsonb := '{}'::jsonb;
  qualifier_option_map jsonb := '{}'::jsonb;
  member_map jsonb := '{}'::jsonb;
  resource_type_map jsonb := '{}'::jsonb;
  service_map jsonb := '{}'::jsonb;
  step_map jsonb := '{}'::jsonb;
  rec record;
  new_id uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select d.* into existing_open_draft
    from app.configuration_drafts d
   where d.tenant_id = target_tenant_id and d.status = 'DRAFT'
   order by d.revision desc
   limit 1;

  if existing_open_draft.id is not null then
    return public.site_load_configuration(target_site_project_id, target_email, target_tenant_id);
  end if;

  select d.* into source_draft
    from app.configuration_drafts d
   where d.tenant_id = target_tenant_id and d.status = 'PUBLISHED'
   order by d.revision desc
   limit 1
   for update;

  if source_draft.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_PUBLISHED_DRAFT_NOT_FOUND';
  end if;

  select coalesce(max(d.revision), 0) + 1 into next_revision
    from app.configuration_drafts d
   where d.tenant_id = target_tenant_id and d.unit_id = source_draft.unit_id;

  insert into app.configuration_drafts (
    tenant_id, unit_id, revision, status, deposit_enabled, channel_mode, final_message_template,
    cancellation_policy_enabled, cancellation_window_hours, cancellation_charge_type,
    cancellation_charge_amount_minor, cancellation_charge_percentage
  ) values (
    source_draft.tenant_id, source_draft.unit_id, next_revision, 'DRAFT',
    source_draft.deposit_enabled, source_draft.channel_mode, source_draft.final_message_template,
    source_draft.cancellation_policy_enabled, source_draft.cancellation_window_hours,
    source_draft.cancellation_charge_type, source_draft.cancellation_charge_amount_minor,
    source_draft.cancellation_charge_percentage
  )
  returning id into new_draft_id;

  for rec in select * from app.skills where configuration_draft_id = source_draft.id
  loop
    insert into app.skills (tenant_id, configuration_draft_id, name, status, qualifier_label, qualifier_allow_custom)
    values (rec.tenant_id, new_draft_id, rec.name, rec.status, rec.qualifier_label, rec.qualifier_allow_custom)
    returning id into new_id;
    skill_map := skill_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.skill_qualifier_options where configuration_draft_id = source_draft.id
  loop
    insert into app.skill_qualifier_options (tenant_id, configuration_draft_id, skill_id, label, position)
    values (rec.tenant_id, new_draft_id, (skill_map ->> rec.skill_id::text)::uuid, rec.label, rec.position)
    returning id into new_id;
    qualifier_option_map := qualifier_option_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.team_members where configuration_draft_id = source_draft.id
  loop
    insert into app.team_members (tenant_id, configuration_draft_id, name, member_type, availability_mode, status)
    values (rec.tenant_id, new_draft_id, rec.name, rec.member_type, rec.availability_mode, rec.status)
    returning id into new_id;
    member_map := member_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.member_skills where configuration_draft_id = source_draft.id
  loop
    insert into app.member_skills (tenant_id, configuration_draft_id, member_id, skill_id, priority)
    values (
      rec.tenant_id, new_draft_id,
      (member_map ->> rec.member_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      rec.priority
    );
  end loop;

  for rec in select * from app.member_skill_qualifiers where configuration_draft_id = source_draft.id
  loop
    insert into app.member_skill_qualifiers (tenant_id, configuration_draft_id, member_id, skill_id, qualifier_option_id, custom_value)
    values (
      rec.tenant_id, new_draft_id,
      (member_map ->> rec.member_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      case when rec.qualifier_option_id is null then null else (qualifier_option_map ->> rec.qualifier_option_id::text)::uuid end,
      rec.custom_value
    );
  end loop;

  for rec in select * from app.member_availability where configuration_draft_id = source_draft.id
  loop
    insert into app.member_availability (tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at)
    values (rec.tenant_id, new_draft_id, (member_map ->> rec.member_id::text)::uuid, rec.weekday, rec.starts_at, rec.ends_at);
  end loop;

  for rec in select * from app.member_dynamic_shifts where configuration_draft_id = source_draft.id
  loop
    insert into app.member_dynamic_shifts (tenant_id, configuration_draft_id, member_id, shift_date, starts_at, ends_at)
    values (rec.tenant_id, new_draft_id, (member_map ->> rec.member_id::text)::uuid, rec.shift_date, rec.starts_at, rec.ends_at);
  end loop;

  for rec in select * from app.resource_types where configuration_draft_id = source_draft.id
  loop
    insert into app.resource_types (tenant_id, configuration_draft_id, name, description)
    values (rec.tenant_id, new_draft_id, rec.name, rec.description)
    returning id into new_id;
    resource_type_map := resource_type_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.resources where configuration_draft_id = source_draft.id
  loop
    insert into app.resources (tenant_id, configuration_draft_id, resource_type_id, name, capacity, status)
    values (
      rec.tenant_id, new_draft_id,
      (resource_type_map ->> rec.resource_type_id::text)::uuid,
      rec.name, rec.capacity, rec.status
    );
  end loop;

  for rec in select * from app.services where configuration_draft_id = source_draft.id
  loop
    insert into app.services (
      tenant_id, configuration_draft_id, name, description, kind, base_price_minor, currency, bookable, status,
      requires_strand_test, strand_test_lead_days, strand_test_duration_minutes, strand_test_preferred_weekdays
    )
    values (
      rec.tenant_id, new_draft_id, rec.name, rec.description, rec.kind, rec.base_price_minor, rec.currency,
      rec.bookable, rec.status, rec.requires_strand_test, rec.strand_test_lead_days,
      rec.strand_test_duration_minutes, rec.strand_test_preferred_weekdays
    )
    returning id into new_id;
    service_map := service_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.service_variations where configuration_draft_id = source_draft.id
  loop
    insert into app.service_variations (tenant_id, configuration_draft_id, service_id, name, classification_values, price_minor, status)
    values (
      rec.tenant_id, new_draft_id, (service_map ->> rec.service_id::text)::uuid,
      rec.name, rec.classification_values, rec.price_minor, rec.status
    );
  end loop;

  for rec in select * from app.service_steps where configuration_draft_id = source_draft.id
  loop
    insert into app.service_steps (
      tenant_id, configuration_draft_id, service_id, name, position, duration_minutes, kind,
      customer_presence_required, releases_member
    )
    values (
      rec.tenant_id, new_draft_id, (service_map ->> rec.service_id::text)::uuid, rec.name, rec.position,
      rec.duration_minutes, rec.kind, rec.customer_presence_required, rec.releases_member
    )
    returning id into new_id;
    step_map := step_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.service_step_skill_requirements where configuration_draft_id = source_draft.id
  loop
    insert into app.service_step_skill_requirements (tenant_id, configuration_draft_id, step_id, skill_id, quantity)
    values (
      rec.tenant_id, new_draft_id,
      (step_map ->> rec.step_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      rec.quantity
    );
  end loop;

  for rec in select * from app.service_step_skill_qualifiers where configuration_draft_id = source_draft.id
  loop
    insert into app.service_step_skill_qualifiers (tenant_id, configuration_draft_id, step_id, skill_id, qualifier_option_id, custom_value)
    values (
      rec.tenant_id, new_draft_id,
      (step_map ->> rec.step_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      case when rec.qualifier_option_id is null then null else (qualifier_option_map ->> rec.qualifier_option_id::text)::uuid end,
      rec.custom_value
    );
  end loop;

  for rec in select * from app.service_step_resource_requirements where configuration_draft_id = source_draft.id
  loop
    insert into app.service_step_resource_requirements (tenant_id, configuration_draft_id, step_id, resource_type_id, quantity, retain_until_service_end)
    values (
      rec.tenant_id, new_draft_id,
      (step_map ->> rec.step_id::text)::uuid,
      (resource_type_map ->> rec.resource_type_id::text)::uuid,
      rec.quantity, rec.retain_until_service_end
    );
  end loop;

  for rec in select * from app.operating_hours where configuration_draft_id = source_draft.id
  loop
    insert into app.operating_hours (tenant_id, configuration_draft_id, weekday, starts_at, ends_at)
    values (rec.tenant_id, new_draft_id, rec.weekday, rec.starts_at, rec.ends_at);
  end loop;

  for rec in select * from app.unit_service_limits where configuration_draft_id = source_draft.id
  loop
    insert into app.unit_service_limits (tenant_id, configuration_draft_id, weekday, latest_end_time)
    values (rec.tenant_id, new_draft_id, rec.weekday, rec.latest_end_time);
  end loop;

  for rec in select * from app.client_schedule_exceptions where configuration_draft_id = source_draft.id
  loop
    insert into app.client_schedule_exceptions (tenant_id, configuration_draft_id, client_name, client_phone_digits, weekday, starts_at, ends_at, note)
    values (rec.tenant_id, new_draft_id, rec.client_name, rec.client_phone_digits, rec.weekday, rec.starts_at, rec.ends_at, rec.note);
  end loop;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    target_tenant_id, 'USER', null, 'CONFIGURATION_DRAFT_STARTED', 'configuration_draft', new_draft_id,
    null, target_correlation_id, 'SUCCESS',
    jsonb_build_object('sourceDraftId', source_draft.id, 'actorEmail', lower(trim(target_email)))
  );

  return public.site_load_configuration(target_site_project_id, target_email, target_tenant_id);
end;
$function$;

commit;
