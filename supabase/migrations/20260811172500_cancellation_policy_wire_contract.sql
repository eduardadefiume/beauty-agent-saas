begin;

create or replace function private.build_configuration_snapshot(target_draft_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'schemaVersion', 1,
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
        from app.operating_hours h
       where h.tenant_id = d.tenant_id and h.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'serviceLimits', coalesce((
      select jsonb_agg(to_jsonb(l) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by l.weekday, l.id)
        from app.unit_service_limits l
       where l.tenant_id = d.tenant_id and l.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'clientExceptions', coalesce((
      select jsonb_agg(to_jsonb(ce) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at'
                       order by ce.client_name, ce.weekday, ce.starts_at, ce.id)
        from app.client_schedule_exceptions ce
       where ce.tenant_id = d.tenant_id and ce.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'skills', coalesce((
      select jsonb_agg(
        (to_jsonb(s) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at')
        || jsonb_build_object(
          'qualifierOptions', coalesce((
            select jsonb_agg(to_jsonb(o) - 'tenant_id' - 'configuration_draft_id' - 'skill_id' - 'created_at' - 'updated_at'
                             order by o.position)
              from app.skill_qualifier_options o
             where o.tenant_id = s.tenant_id
               and o.configuration_draft_id = s.configuration_draft_id
               and o.skill_id = s.id
          ), '[]'::jsonb)
        )
        order by s.name, s.id)
        from app.skills s
       where s.tenant_id = d.tenant_id and s.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'teamMembers', coalesce((
      select jsonb_agg(
        (to_jsonb(m) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at')
        || jsonb_build_object(
          'skillIds', coalesce((
            select jsonb_agg(ms.skill_id order by ms.priority, ms.skill_id)
              from app.member_skills ms
             where ms.tenant_id = m.tenant_id
               and ms.configuration_draft_id = m.configuration_draft_id
               and ms.member_id = m.id
          ), '[]'::jsonb),
          'skillQualifiers', coalesce((
            select jsonb_agg(to_jsonb(q) - 'tenant_id' - 'configuration_draft_id' - 'member_id' - 'created_at'
                             order by q.skill_id, q.qualifier_option_id)
              from app.member_skill_qualifiers q
             where q.tenant_id = m.tenant_id
               and q.configuration_draft_id = m.configuration_draft_id
               and q.member_id = m.id
          ), '[]'::jsonb),
          'availability', coalesce((
            select jsonb_agg(to_jsonb(a) - 'tenant_id' - 'configuration_draft_id' - 'member_id' - 'created_at' - 'updated_at'
                             order by a.weekday, a.starts_at, a.id)
              from app.member_availability a
             where a.tenant_id = m.tenant_id
               and a.configuration_draft_id = m.configuration_draft_id
               and a.member_id = m.id
          ), '[]'::jsonb),
          'dynamicShifts', coalesce((
            select jsonb_agg(to_jsonb(ds) - 'tenant_id' - 'configuration_draft_id' - 'member_id' - 'created_at' - 'updated_at'
                             order by ds.shift_date, ds.starts_at, ds.id)
              from app.member_dynamic_shifts ds
             where ds.tenant_id = m.tenant_id
               and ds.configuration_draft_id = m.configuration_draft_id
               and ds.member_id = m.id
          ), '[]'::jsonb)
        )
        order by m.name, m.id
      )
        from app.team_members m
       where m.tenant_id = d.tenant_id and m.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'resourceTypes', coalesce((
      select jsonb_agg(
        (to_jsonb(rt) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at')
        || jsonb_build_object(
          'resources', coalesce((
            select jsonb_agg(to_jsonb(r) - 'tenant_id' - 'configuration_draft_id' - 'resource_type_id' - 'created_at' - 'updated_at'
                             order by r.name, r.id)
              from app.resources r
             where r.tenant_id = rt.tenant_id
               and r.configuration_draft_id = rt.configuration_draft_id
               and r.resource_type_id = rt.id
          ), '[]'::jsonb)
        )
        order by rt.name, rt.id
      )
        from app.resource_types rt
       where rt.tenant_id = d.tenant_id and rt.configuration_draft_id = d.id
    ), '[]'::jsonb),
    'services', coalesce((
      select jsonb_agg(
        (to_jsonb(svc) - 'tenant_id' - 'configuration_draft_id' - 'created_at' - 'updated_at')
        || jsonb_build_object(
          'variations', coalesce((
            select jsonb_agg(to_jsonb(v) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at'
                             order by v.name, v.id)
              from app.service_variations v
             where v.tenant_id = svc.tenant_id
               and v.configuration_draft_id = svc.configuration_draft_id
               and v.service_id = svc.id
          ), '[]'::jsonb),
          'steps', coalesce((
            select jsonb_agg(
              (to_jsonb(st) - 'tenant_id' - 'configuration_draft_id' - 'service_id' - 'created_at' - 'updated_at')
              || jsonb_build_object(
                'skillRequirements', coalesce((
                  select jsonb_agg(
                    (to_jsonb(sr) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'created_at')
                    || jsonb_build_object(
                      'qualifier', (
                        select to_jsonb(q) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'skill_id' - 'created_at'
                          from app.service_step_skill_qualifiers q
                         where q.tenant_id = sr.tenant_id
                           and q.configuration_draft_id = sr.configuration_draft_id
                           and q.step_id = sr.step_id
                           and q.skill_id = sr.skill_id
                         limit 1
                      )
                    )
                    order by sr.skill_id)
                    from app.service_step_skill_requirements sr
                   where sr.tenant_id = st.tenant_id
                     and sr.configuration_draft_id = st.configuration_draft_id
                     and sr.step_id = st.id
                ), '[]'::jsonb),
                'resourceRequirements', coalesce((
                  select jsonb_agg(to_jsonb(rr) - 'tenant_id' - 'configuration_draft_id' - 'step_id' - 'created_at'
                                   order by rr.resource_type_id)
                    from app.service_step_resource_requirements rr
                   where rr.tenant_id = st.tenant_id
                     and rr.configuration_draft_id = st.configuration_draft_id
                     and rr.step_id = st.id
                ), '[]'::jsonb)
              )
              order by st.position, st.id
            )
              from app.service_steps st
             where st.tenant_id = svc.tenant_id
               and st.configuration_draft_id = svc.configuration_draft_id
               and st.service_id = svc.id
          ), '[]'::jsonb)
        )
        order by svc.name, svc.id
      )
        from app.services svc
       where svc.tenant_id = d.tenant_id and svc.configuration_draft_id = d.id
    ), '[]'::jsonb)
  )
    from app.configuration_drafts d
   where d.id = target_draft_id
$function$;

create or replace function public.site_replace_configuration(target_site_project_id text, target_email text, target_tenant_id uuid, expected_revision integer, payload jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  draft_record app.configuration_drafts%rowtype;
  hour_item jsonb;
  skill_item jsonb;
  member_item jsonb;
  availability_item jsonb;
  dynamic_shift_item jsonb;
  client_exception_item jsonb;
  resource_type_item jsonb;
  resource_item jsonb;
  service_item jsonb;
  variation_item jsonb;
  step_item jsonb;
  requirement_item jsonb;
  option_item jsonb;
  qualifier_item jsonb;
  member_id_value uuid;
  service_id_value uuid;
  step_id_value uuid;
  resource_type_id_value uuid;
  skill_id_value uuid;
  qualifier_option_id_value uuid;
  option_position integer;
  skill_name_value text;
  skill_qualifier_label_value text;
  skill_qualifier_allow_custom_value boolean;
  strand_test_weekdays_value smallint[];
  next_revision integer;
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if jsonb_typeof(payload) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_CONFIGURATION_PAYLOAD';
  end if;

  select configuration_draft.*
    into draft_record
    from app.configuration_drafts configuration_draft
   where configuration_draft.tenant_id = target_tenant_id
     and configuration_draft.status = 'DRAFT'
   order by configuration_draft.revision desc
   limit 1
   for update;

  if draft_record.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_DRAFT_NOT_FOUND';
  end if;

  if draft_record.revision <> expected_revision then
    raise exception using errcode = '40001', message = 'CONFIGURATION_REVISION_CONFLICT';
  end if;

  update app.units
     set name = coalesce(nullif(trim(payload #>> '{unit,name}'), ''), name),
         timezone = coalesce(nullif(trim(payload #>> '{unit,timezone}'), ''), timezone)
   where id = draft_record.unit_id
     and tenant_id = draft_record.tenant_id;

  delete from app.service_step_resource_requirements where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.service_step_skill_requirements where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.service_steps where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.service_variations where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.services where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.resources where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.resource_types where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.member_dynamic_shifts where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.member_availability where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.member_skills where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.team_members where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.skills where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.client_schedule_exceptions where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.unit_service_limits where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.operating_hours where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;

  for hour_item in select value from jsonb_array_elements(coalesce(payload->'operatingHours', '[]'::jsonb))
  loop
    insert into app.operating_hours (
      tenant_id, configuration_draft_id, weekday, starts_at, ends_at
    ) values (
      target_tenant_id,
      draft_record.id,
      (hour_item->>'weekday')::smallint,
      (hour_item->>'startsAt')::time,
      (hour_item->>'endsAt')::time
    );

    insert into app.unit_service_limits (
      tenant_id, configuration_draft_id, weekday, latest_end_time
    ) values (
      target_tenant_id,
      draft_record.id,
      (hour_item->>'weekday')::smallint,
      coalesce(nullif(hour_item->>'latestEndTime', '')::time, (hour_item->>'endsAt')::time)
    );
  end loop;

  for client_exception_item in select value from jsonb_array_elements(coalesce(payload->'clientExceptions', '[]'::jsonb))
  loop
    insert into app.client_schedule_exceptions (
      tenant_id, configuration_draft_id, client_name, client_phone_digits, weekday, starts_at, ends_at, note
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(client_exception_item->>'clientName'),
      nullif(trim(coalesce(client_exception_item->>'clientPhoneDigits', '')), ''),
      (client_exception_item->>'weekday')::smallint,
      (client_exception_item->>'startsAt')::time,
      (client_exception_item->>'endsAt')::time,
      nullif(trim(coalesce(client_exception_item->>'note', '')), '')
    );
  end loop;

  for skill_item in select value from jsonb_array_elements(coalesce(payload->'skills', '[]'::jsonb))
  loop
    if jsonb_typeof(skill_item) = 'object' then
      skill_name_value := trim(skill_item->>'name');
      skill_qualifier_label_value := nullif(trim(coalesce(skill_item->>'qualifierLabel', '')), '');
      skill_qualifier_allow_custom_value := coalesce((skill_item->>'qualifierAllowCustom')::boolean, false);
    else
      skill_name_value := trim(skill_item #>> '{}');
      skill_qualifier_label_value := null;
      skill_qualifier_allow_custom_value := false;
    end if;

    insert into app.skills (tenant_id, configuration_draft_id, name, qualifier_label, qualifier_allow_custom)
    values (target_tenant_id, draft_record.id, skill_name_value, skill_qualifier_label_value, skill_qualifier_allow_custom_value)
    returning id into skill_id_value;

    if jsonb_typeof(skill_item) = 'object' then
      option_position := 0;
      for option_item in select value from jsonb_array_elements(coalesce(skill_item->'qualifierOptions', '[]'::jsonb))
      loop
        option_position := option_position + 1;
        insert into app.skill_qualifier_options (tenant_id, configuration_draft_id, skill_id, label, position)
        values (target_tenant_id, draft_record.id, skill_id_value, trim(option_item #>> '{}'), option_position);
      end loop;
    end if;
  end loop;

  for member_item in select value from jsonb_array_elements(coalesce(payload->'teamMembers', '[]'::jsonb))
  loop
    insert into app.team_members (
      tenant_id, configuration_draft_id, name, member_type, availability_mode
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(member_item->>'name'),
      coalesce(nullif(member_item->>'memberType', ''), 'PROFESSIONAL'),
      coalesce(nullif(member_item->>'availabilityMode', ''), 'FIXED')::app.availability_mode
    )
    returning id into member_id_value;

    for skill_item in select value from jsonb_array_elements(coalesce(member_item->'skillNames', '[]'::jsonb))
    loop
      select skill.id into skill_id_value
        from app.skills skill
       where skill.tenant_id = target_tenant_id
         and skill.configuration_draft_id = draft_record.id
         and skill.name = trim(skill_item #>> '{}');

      if skill_id_value is null then
        raise exception using errcode = '23503', message = 'MEMBER_SKILL_NOT_FOUND';
      end if;

      insert into app.member_skills (
        tenant_id, configuration_draft_id, member_id, skill_id
      ) values (
        target_tenant_id, draft_record.id, member_id_value, skill_id_value
      );
    end loop;

    for qualifier_item in select value from jsonb_array_elements(coalesce(member_item->'skillQualifiers', '[]'::jsonb))
    loop
      select skill.id into skill_id_value
        from app.skills skill
       where skill.tenant_id = target_tenant_id
         and skill.configuration_draft_id = draft_record.id
         and skill.name = trim(qualifier_item->>'skillName');

      if skill_id_value is null then
        raise exception using errcode = '23503', message = 'MEMBER_SKILL_QUALIFIER_SKILL_NOT_FOUND';
      end if;

      if nullif(trim(coalesce(qualifier_item->>'customValue', '')), '') is not null then
        insert into app.member_skill_qualifiers (
          tenant_id, configuration_draft_id, member_id, skill_id, qualifier_option_id, custom_value
        ) values (
          target_tenant_id, draft_record.id, member_id_value, skill_id_value, null, trim(qualifier_item->>'customValue')
        );
      else
        select option.id into qualifier_option_id_value
          from app.skill_qualifier_options option
         where option.tenant_id = target_tenant_id
           and option.configuration_draft_id = draft_record.id
           and option.skill_id = skill_id_value
           and option.label = trim(qualifier_item->>'optionLabel');

        if qualifier_option_id_value is null then
          raise exception using errcode = '23503', message = 'MEMBER_SKILL_QUALIFIER_OPTION_NOT_FOUND';
        end if;

        insert into app.member_skill_qualifiers (
          tenant_id, configuration_draft_id, member_id, skill_id, qualifier_option_id, custom_value
        ) values (
          target_tenant_id, draft_record.id, member_id_value, skill_id_value, qualifier_option_id_value, null
        );
      end if;
    end loop;

    for availability_item in select value from jsonb_array_elements(coalesce(member_item->'availability', '[]'::jsonb))
    loop
      insert into app.member_availability (
        tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at
      ) values (
        target_tenant_id,
        draft_record.id,
        member_id_value,
        (availability_item->>'weekday')::smallint,
        (availability_item->>'startsAt')::time,
        (availability_item->>'endsAt')::time
      );
    end loop;

    for dynamic_shift_item in select value from jsonb_array_elements(coalesce(member_item->'dynamicShifts', '[]'::jsonb))
    loop
      insert into app.member_dynamic_shifts (
        tenant_id, configuration_draft_id, member_id, shift_date, starts_at, ends_at
      ) values (
        target_tenant_id,
        draft_record.id,
        member_id_value,
        (dynamic_shift_item->>'shiftDate')::date,
        (dynamic_shift_item->>'startsAt')::time,
        (dynamic_shift_item->>'endsAt')::time
      );
    end loop;
  end loop;

  for resource_type_item in select value from jsonb_array_elements(coalesce(payload->'resourceTypes', '[]'::jsonb))
  loop
    insert into app.resource_types (
      tenant_id, configuration_draft_id, name, description
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(resource_type_item->>'name'),
      nullif(trim(coalesce(resource_type_item->>'description', '')), '')
    )
    returning id into resource_type_id_value;

    for resource_item in select value from jsonb_array_elements(coalesce(resource_type_item->'resources', '[]'::jsonb))
    loop
      insert into app.resources (
        tenant_id, configuration_draft_id, resource_type_id, name, capacity
      ) values (
        target_tenant_id,
        draft_record.id,
        resource_type_id_value,
        trim(resource_item->>'name'),
        coalesce((resource_item->>'capacity')::integer, 1)
      );
    end loop;
  end loop;

  for service_item in select value from jsonb_array_elements(coalesce(payload->'services', '[]'::jsonb))
  loop
    if jsonb_typeof(coalesce(service_item->'strandTestPreferredWeekdays', 'null'::jsonb)) = 'array' then
      select coalesce(array_agg((value #>> '{}')::smallint), '{4,5}'::smallint[])
        into strand_test_weekdays_value
        from jsonb_array_elements(service_item->'strandTestPreferredWeekdays');
    else
      strand_test_weekdays_value := '{4,5}'::smallint[];
    end if;

    insert into app.services (
      tenant_id, configuration_draft_id, name, description, kind,
      base_price_minor, currency, bookable,
      requires_strand_test, strand_test_lead_days, strand_test_duration_minutes,
      strand_test_preferred_weekdays
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(service_item->>'name'),
      nullif(trim(coalesce(service_item->>'description', '')), ''),
      coalesce(nullif(service_item->>'kind', ''), 'SIMPLE')::app.service_kind,
      nullif(service_item->>'basePriceMinor', '')::integer,
      'BRL',
      coalesce((service_item->>'bookable')::boolean, true),
      coalesce((service_item->>'requiresStrandTest')::boolean, false),
      coalesce(nullif(service_item->>'strandTestLeadDays', '')::smallint, 7),
      coalesce(nullif(service_item->>'strandTestDurationMinutes', '')::smallint, 60),
      strand_test_weekdays_value
    )
    returning id into service_id_value;

    for variation_item in select value from jsonb_array_elements(coalesce(service_item->'variations', '[]'::jsonb))
    loop
      insert into app.service_variations (
        tenant_id, configuration_draft_id, service_id, name,
        classification_values, price_minor
      ) values (
        target_tenant_id,
        draft_record.id,
        service_id_value,
        trim(variation_item->>'name'),
        coalesce(variation_item->'classificationValues', '{}'::jsonb),
        nullif(variation_item->>'priceMinor', '')::integer
      );
    end loop;

    for step_item in select value from jsonb_array_elements(coalesce(service_item->'steps', '[]'::jsonb))
    loop
      insert into app.service_steps (
        tenant_id, configuration_draft_id, service_id, name, position,
        duration_minutes, kind, customer_presence_required, releases_member
      ) values (
        target_tenant_id,
        draft_record.id,
        service_id_value,
        trim(step_item->>'name'),
        (step_item->>'position')::integer,
        (step_item->>'durationMinutes')::integer,
        coalesce(nullif(step_item->>'kind', ''), 'ACTIVE')::app.step_kind,
        coalesce((step_item->>'customerPresenceRequired')::boolean, true),
        coalesce((step_item->>'releasesMember')::boolean, false)
      )
      returning id into step_id_value;

      for skill_item in select value from jsonb_array_elements(coalesce(step_item->'skillNames', '[]'::jsonb))
      loop
        select skill.id into skill_id_value
          from app.skills skill
         where skill.tenant_id = target_tenant_id
           and skill.configuration_draft_id = draft_record.id
           and skill.name = trim(skill_item #>> '{}');

        if skill_id_value is null then
          raise exception using errcode = '23503', message = 'STEP_SKILL_NOT_FOUND';
        end if;

        insert into app.service_step_skill_requirements (
          tenant_id, configuration_draft_id, step_id, skill_id, quantity
        ) values (
          target_tenant_id, draft_record.id, step_id_value, skill_id_value, 1
        );
      end loop;

      for qualifier_item in select value from jsonb_array_elements(coalesce(step_item->'skillQualifiers', '[]'::jsonb))
      loop
        select skill.id into skill_id_value
          from app.skills skill
         where skill.tenant_id = target_tenant_id
           and skill.configuration_draft_id = draft_record.id
           and skill.name = trim(qualifier_item->>'skillName');

        if skill_id_value is null then
          raise exception using errcode = '23503', message = 'STEP_SKILL_QUALIFIER_SKILL_NOT_FOUND';
        end if;

        if nullif(trim(coalesce(qualifier_item->>'customValue', '')), '') is not null then
          insert into app.service_step_skill_qualifiers (
            tenant_id, configuration_draft_id, step_id, skill_id, qualifier_option_id, custom_value
          ) values (
            target_tenant_id, draft_record.id, step_id_value, skill_id_value, null, trim(qualifier_item->>'customValue')
          );
        else
          select option.id into qualifier_option_id_value
            from app.skill_qualifier_options option
           where option.tenant_id = target_tenant_id
             and option.configuration_draft_id = draft_record.id
             and option.skill_id = skill_id_value
             and option.label = trim(qualifier_item->>'optionLabel');

          if qualifier_option_id_value is null then
            raise exception using errcode = '23503', message = 'STEP_SKILL_QUALIFIER_OPTION_NOT_FOUND';
          end if;

          insert into app.service_step_skill_qualifiers (
            tenant_id, configuration_draft_id, step_id, skill_id, qualifier_option_id, custom_value
          ) values (
            target_tenant_id, draft_record.id, step_id_value, skill_id_value, qualifier_option_id_value, null
          );
        end if;
      end loop;

      for requirement_item in select value from jsonb_array_elements(coalesce(step_item->'resourceRequirements', '[]'::jsonb))
      loop
        select resource_type.id into resource_type_id_value
          from app.resource_types resource_type
         where resource_type.tenant_id = target_tenant_id
           and resource_type.configuration_draft_id = draft_record.id
           and resource_type.name = trim(requirement_item->>'resourceTypeName');

        if resource_type_id_value is null then
          raise exception using errcode = '23503', message = 'STEP_RESOURCE_TYPE_NOT_FOUND';
        end if;

        insert into app.service_step_resource_requirements (
          tenant_id, configuration_draft_id, step_id, resource_type_id,
          quantity, retain_until_service_end
        ) values (
          target_tenant_id,
          draft_record.id,
          step_id_value,
          resource_type_id_value,
          coalesce((requirement_item->>'quantity')::integer, 1),
          coalesce((requirement_item->>'retainUntilServiceEnd')::boolean, false)
        );
      end loop;
    end loop;
  end loop;

  next_revision := draft_record.revision + 1;

  update app.configuration_drafts
     set revision = next_revision,
         final_message_template = nullif(trim(coalesce(payload->>'finalMessageTemplate', '')), ''),
         deposit_enabled = false,
         channel_mode = 'RESTRICTED',
         cancellation_policy_enabled = coalesce((payload->>'cancellationPolicyEnabled')::boolean, false),
         cancellation_window_hours = coalesce(nullif(payload->>'cancellationWindowHours', '')::smallint, 24),
         cancellation_charge_type = nullif(payload->>'cancellationChargeType', ''),
         cancellation_charge_amount_minor = nullif(payload->>'cancellationChargeAmountMinor', '')::integer,
         cancellation_charge_percentage = nullif(payload->>'cancellationChargePercentage', '')::smallint,
         updated_by = null
   where id = draft_record.id;

  return public.site_load_configuration(
    target_site_project_id,
    target_email,
    target_tenant_id
  );
end;
$function$;

commit;
