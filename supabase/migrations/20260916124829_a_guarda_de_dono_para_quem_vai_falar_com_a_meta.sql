create or replace function public.site_assert_owner(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.site_assert_owner(text, text, uuid) from public, anon, authenticated;
grant execute on function public.site_assert_owner(text, text, uuid) to service_role;

notify pgrst, 'reload schema';