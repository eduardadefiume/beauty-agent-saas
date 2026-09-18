-- F0-01b: complementa F0-01 e e a migracao que efetivamente fecha o acesso.
--
-- A migracao 20260817140000 revogou EXECUTE dos papeis nominais anon/authenticated,
-- mas nao surtiu efeito: no PostgreSQL, CREATE FUNCTION concede EXECUTE a PUBLIC
-- por padrao, e anon/authenticated herdam desse grant. Apos o revoke nominal, o
-- ACL destas funcoes ainda continha "=X/postgres", que representa PUBLIC.
--
-- Estado alvo, identico ao ja praticado por schedule_confirm_hold e demais RPCs
-- corrigidas: ACL contendo apenas postgres e service_role.
--
-- Verificacao apos aplicar:
--   select p.proname,
--          has_function_privilege('anon', p.oid, 'EXECUTE')         as anon_pode,
--          has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role_pode
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public';
-- Esperado para as 10 funcoes: anon_pode = false, service_role_pode = true.

revoke execute on function public.site_list_calendar_connections_for_sync(target_site_project_id text, target_email text, target_tenant_id uuid) from public;

revoke execute on function public.site_save_calendar_connection(target_site_project_id text, target_email text, target_tenant_id uuid, target_provider text, target_member_name text, target_external_account_email text, target_calendar_id text, target_access_token text, target_refresh_token text, target_token_expires_at timestamp with time zone, target_scope text) from public;

revoke execute on function public.site_record_calendar_shift_sync(target_site_project_id text, target_email text, target_tenant_id uuid, target_connection_id uuid, target_window_start timestamp with time zone, target_window_end timestamp with time zone, target_events jsonb, target_new_access_token text, target_new_token_expires_at timestamp with time zone, target_error text) from public;

revoke execute on function public.site_disconnect_calendar_connection(target_site_project_id text, target_email text, target_tenant_id uuid, target_connection_id uuid) from public;

revoke execute on function public.site_list_calendar_connections(target_site_project_id text, target_email text, target_tenant_id uuid) from public;

revoke execute on function public.site_list_calendar_shifts(target_site_project_id text, target_email text, target_tenant_id uuid) from public;

revoke execute on function public.site_start_new_draft(target_site_project_id text, target_email text, target_tenant_id uuid, target_correlation_id text) from public;

revoke execute on function public.schedule_list_calendar_shifts(target_site_project_id text, target_email text, target_tenant_id uuid, target_unit_id uuid) from public;

revoke execute on function public.schedule_list_strand_test_occupancies(target_site_project_id text, target_email text, target_tenant_id uuid, target_unit_id uuid) from public;

revoke execute on function public.schedule_record_strand_test_booking(target_site_project_id text, target_email text, target_tenant_id uuid, target_unit_id uuid, target_main_appointment_id uuid, target_member_id uuid, target_member_name text, target_resource_id uuid, target_starts_at timestamp with time zone, target_ends_at timestamp with time zone, target_correlation_id text) from public;
