begin;

-- Fecha o contrato dos qualificadores de competência nos três lugares que
-- precisam concordar: o snapshot publicado (o que o motor de agenda lê), a
-- checagem de prontidão (o que bloqueia publicar), e a RPC que grava o
-- rascunho a partir do payload do configurador.

create or replace function private.build_configuration_snapshot(target_draft_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'schemaVersion', 1,
    'tenantId', d.tenant_id,
    'unitId', d.unit_id,
    'sourceDraftId', d.id,
    'sourceRevision', d.revision,
    'depositEnabled', d.deposit_enabled,
    'channelMode', d.channel_mode,
    'finalMessageTemplate', d.final_message_template,
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
$$;

create or replace function private.configuration_readiness(target_draft_id uuid)
returns table (
  code text,
  entity_type text,
  entity_id uuid,
  field_path text
)
language sql
stable
security definer
set search_path = ''
as $$
  with draft as (
    select d.id, d.tenant_id, d.unit_id, d.final_message_template
      from app.configuration_drafts d
     where d.id = target_draft_id
  )
  select 'UNIT_TIMEZONE_MISSING', 'unit', u.id, 'unit.timezone'
    from draft d
    join app.units u on u.id = d.unit_id and u.tenant_id = d.tenant_id
   where not exists (
     select 1 from pg_catalog.pg_timezone_names tz where tz.name = u.timezone
   )
  union all
  select 'OPERATING_HOURS_MISSING', 'configuration_draft', d.id, 'operatingHours'
    from draft d
   where not exists (
     select 1 from app.operating_hours h
      where h.tenant_id = d.tenant_id and h.configuration_draft_id = d.id
   )
  union all
  select 'LATEST_END_MISSING', 'configuration_draft', d.id, 'serviceLimits'
    from draft d
   where exists (
     select 1
       from app.operating_hours h
      where h.tenant_id = d.tenant_id
        and h.configuration_draft_id = d.id
        and not exists (
          select 1
            from app.unit_service_limits l
           where l.tenant_id = h.tenant_id
             and l.configuration_draft_id = h.configuration_draft_id
             and l.weekday = h.weekday
        )
   )
  union all
  select 'NO_ACTIVE_MEMBER', 'configuration_draft', d.id, 'teamMembers'
    from draft d
   where not exists (
     select 1 from app.team_members m
      where m.tenant_id = d.tenant_id
        and m.configuration_draft_id = d.id
        and m.status = 'ACTIVE'
   )
  union all
  select 'MEMBER_AVAILABILITY_INVALID', 'team_member', m.id, 'teamMembers.availability'
    from draft d
    join app.team_members m
      on m.tenant_id = d.tenant_id and m.configuration_draft_id = d.id
   where m.status = 'ACTIVE'
     and m.availability_mode in ('FIXED', 'HYBRID')
     and not exists (
       select 1 from app.member_availability a
        where a.tenant_id = m.tenant_id
          and a.configuration_draft_id = m.configuration_draft_id
          and a.member_id = m.id
     )
  union all
  select 'NO_BOOKABLE_SERVICE', 'configuration_draft', d.id, 'services'
    from draft d
   where not exists (
     select 1 from app.services s
      where s.tenant_id = d.tenant_id
        and s.configuration_draft_id = d.id
        and s.status = 'ACTIVE'
        and s.bookable
   )
  union all
  select 'SERVICE_HAS_NO_STEPS', 'service', s.id, 'services.steps'
    from draft d
    join app.services s
      on s.tenant_id = d.tenant_id and s.configuration_draft_id = d.id
   where s.status = 'ACTIVE'
     and s.bookable
     and not exists (
       select 1 from app.service_steps st
        where st.tenant_id = s.tenant_id
          and st.configuration_draft_id = s.configuration_draft_id
          and st.service_id = s.id
     )
  union all
  select 'STEP_SKILL_QUALIFIER_MISSING', 'service_step', st.id, 'services.steps.skills.qualifier'
    from draft d
    join app.service_steps st
      on st.tenant_id = d.tenant_id and st.configuration_draft_id = d.id
    join app.service_step_skill_requirements req
      on req.tenant_id = st.tenant_id
     and req.configuration_draft_id = st.configuration_draft_id
     and req.step_id = st.id
    join app.skills sk
      on sk.tenant_id = req.tenant_id
     and sk.configuration_draft_id = req.configuration_draft_id
     and sk.id = req.skill_id
   where sk.qualifier_label is not null
     and not exists (
       select 1 from app.service_step_skill_qualifiers q
        where q.tenant_id = req.tenant_id
          and q.configuration_draft_id = req.configuration_draft_id
          and q.step_id = req.step_id
          and q.skill_id = req.skill_id
     )
  union all
  select 'STEP_HAS_NO_QUALIFIED_MEMBER', 'service_step', st.id, 'services.steps.skills'
    from draft d
    join app.service_steps st
      on st.tenant_id = d.tenant_id and st.configuration_draft_id = d.id
   where st.kind = 'ACTIVE'
     and (
       not exists (
         select 1 from app.service_step_skill_requirements req
          where req.tenant_id = st.tenant_id
            and req.configuration_draft_id = st.configuration_draft_id
            and req.step_id = st.id
       )
       or exists (
         select 1
           from app.service_step_skill_requirements req
          where req.tenant_id = st.tenant_id
            and req.configuration_draft_id = st.configuration_draft_id
            and req.step_id = st.id
            and (
              select count(*)
                from app.member_skills ms
                join app.team_members m
                  on m.tenant_id = ms.tenant_id
                 and m.configuration_draft_id = ms.configuration_draft_id
                 and m.id = ms.member_id
                 and m.status = 'ACTIVE'
               where ms.tenant_id = req.tenant_id
                 and ms.configuration_draft_id = req.configuration_draft_id
                 and ms.skill_id = req.skill_id
                 and (
                   not exists (
                     select 1 from app.service_step_skill_qualifiers q
                      where q.tenant_id = req.tenant_id
                        and q.configuration_draft_id = req.configuration_draft_id
                        and q.step_id = req.step_id
                        and q.skill_id = req.skill_id
                   )
                   or exists (
                     select 1
                       from app.service_step_skill_qualifiers q
                       join app.member_skill_qualifiers mq
                         on mq.tenant_id = q.tenant_id
                        and mq.configuration_draft_id = q.configuration_draft_id
                        and mq.member_id = m.id
                        and mq.skill_id = q.skill_id
                        and (
                          (q.qualifier_option_id is not null and mq.qualifier_option_id = q.qualifier_option_id)
                          or (
                            q.qualifier_option_id is null and q.custom_value is not null
                            and mq.custom_value is not null
                            and lower(trim(mq.custom_value)) = lower(trim(q.custom_value))
                          )
                        )
                      where q.tenant_id = req.tenant_id
                        and q.configuration_draft_id = req.configuration_draft_id
                        and q.step_id = req.step_id
                        and q.skill_id = req.skill_id
                   )
                 )
            ) < req.quantity
       )
     )
  union all
  select 'RESOURCE_CAPACITY_MISSING', 'service_step', st.id, 'services.steps.resources'
    from draft d
    join app.service_steps st
      on st.tenant_id = d.tenant_id and st.configuration_draft_id = d.id
    join app.service_step_resource_requirements req
      on req.tenant_id = st.tenant_id
     and req.configuration_draft_id = st.configuration_draft_id
     and req.step_id = st.id
   where (
     select coalesce(sum(r.capacity), 0)
       from app.resources r
      where r.tenant_id = req.tenant_id
        and r.configuration_draft_id = req.configuration_draft_id
        and r.resource_type_id = req.resource_type_id
        and r.status = 'ACTIVE'
   ) < req.quantity
  union all
  select 'FINAL_MESSAGE_MISSING', 'configuration_draft', d.id, 'finalMessageTemplate'
    from draft d
   where nullif(trim(d.final_message_template), '') is null
$$;

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
as $$
declare
  draft_record app.configuration_drafts%rowtype;
  hour_item jsonb;
  skill_item jsonb;
  member_item jsonb;
  availability_item jsonb;
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
  delete from app.member_availability where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.member_skills where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.team_members where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
  delete from app.skills where configuration_draft_id = draft_record.id and tenant_id = target_tenant_id;
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

  -- skills aceita tanto o formato antigo (string simples, sem qualificador)
  -- quanto o novo objeto {name, qualifierLabel?, qualifierAllowCustom?, qualifierOptions?}.
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

    -- Quais opções do qualificador esta pessoa cobre, por competência.
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
    insert into app.services (
      tenant_id, configuration_draft_id, name, description, kind,
      base_price_minor, currency, bookable
    ) values (
      target_tenant_id,
      draft_record.id,
      trim(service_item->>'name'),
      nullif(trim(coalesce(service_item->>'description', '')), ''),
      coalesce(nullif(service_item->>'kind', ''), 'SIMPLE')::app.service_kind,
      nullif(service_item->>'basePriceMinor', '')::integer,
      'BRL',
      coalesce((service_item->>'bookable')::boolean, true)
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

      -- Qual opção do qualificador esta etapa exige, por competência.
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
         updated_by = null
   where id = draft_record.id;

  return public.site_load_configuration(
    target_site_project_id,
    target_email,
    target_tenant_id
  );
end;
$$;

commit;
