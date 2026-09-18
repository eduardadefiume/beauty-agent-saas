begin;

-- Leitura da configuração publicada ativa (snapshot imutável), pelo mesmo
-- portão de autorização (site_identities) das demais RPCs de agenda.
-- É o que o Edge Function scheduling-api usa para alimentar o motor puro
-- (@beauty/scheduling-engine): nada de reconsultar tabelas de rascunho.

create or replace function public.schedule_get_active_configuration(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  unit_record app.units%rowtype;
  version_record app.configuration_versions%rowtype;
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  select u.* into unit_record
    from app.units u
   where u.id = target_unit_id and u.tenant_id = target_tenant_id;

  if unit_record.id is null then
    raise exception using errcode = '42501', message = 'UNIT_NOT_ACCESSIBLE';
  end if;

  if unit_record.active_configuration_version_id is null then
    raise exception using errcode = 'P0002', message = 'NO_PUBLISHED_CONFIGURATION';
  end if;

  select v.* into version_record
    from app.configuration_versions v
   where v.id = unit_record.active_configuration_version_id and v.tenant_id = target_tenant_id;

  return jsonb_build_object(
    'configurationVersionId', version_record.id,
    'versionNumber', version_record.version_number,
    'timezone', unit_record.timezone,
    'snapshot', version_record.snapshot
  );
end;
$$;

revoke all on function public.schedule_get_active_configuration(text, text, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.schedule_get_active_configuration(text, text, uuid, uuid) to service_role;

commit;
