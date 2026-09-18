drop function if exists public.agent_set_scheduling_focus(uuid, uuid, uuid, uuid, jsonb);
drop function if exists app.agent_set_scheduling_focus(uuid, uuid, uuid, uuid, jsonb);

create function app.agent_set_scheduling_focus(
  p_tenant_id                uuid,
  p_conversation_id          uuid,
  p_service_id               uuid,
  p_configuration_version_id uuid,
  p_candidates               jsonb
) returns jsonb
language sql
security definer
set search_path = app, public
as $$
  insert into app.agent_scheduling_focus as f
    (conversation_id, tenant_id, service_id, configuration_version_id, candidates, searched_at)
  values
    (p_conversation_id, p_tenant_id, p_service_id, p_configuration_version_id,
     coalesce(p_candidates, '[]'::jsonb), now())
  on conflict (conversation_id) do update
    set tenant_id                = excluded.tenant_id,
        service_id               = excluded.service_id,
        configuration_version_id = excluded.configuration_version_id,
        candidates               = excluded.candidates,
        searched_at              = excluded.searched_at;

  select app.agent_scheduling_focus(p_conversation_id);
$$;

create function public.agent_set_scheduling_focus(
  p_tenant_id uuid, p_conversation_id uuid, p_service_id uuid,
  p_configuration_version_id uuid, p_candidates jsonb
) returns jsonb language sql security definer set search_path = app, public as $$
  select app.agent_set_scheduling_focus(p_tenant_id, p_conversation_id, p_service_id,
                                        p_configuration_version_id, p_candidates);
$$;

revoke all on function public.agent_set_scheduling_focus(uuid, uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.agent_set_scheduling_focus(uuid, uuid, uuid, uuid, jsonb) to service_role;