-- F0-01: fecha RPCs SECURITY DEFINER expostas aos papeis anon/authenticated.
--
-- Motivo: private.require_site_tenant() autoriza usando APENAS os parametros
-- enviados pelo proprio chamador (site_project_id, email, tenant_id). Nao ha
-- auth.uid(), sessao nem segredo. Combinado com o EXECUTE concedido a anon,
-- qualquer pessoa com a chave publicavel podia chamar estas funcoes -- inclusive
-- site_list_calendar_connections_for_sync, que retorna access_token e
-- refresh_token do Google em texto claro.
--
-- Seguranca da mudanca: as 10 funcoes abaixo sao chamadas exclusivamente pelas
-- Edge Functions owner-console-api e scheduling-api, que usam service_role.
-- service_role mantem EXECUTE em todas elas, portanto nenhum caminho de produto
-- e afetado.
--
-- NAO incluida aqui: public.resolve_login_email(text). Ela e chamada com a chave
-- anon por apps/web/app/api/auth/login/route.ts e signup/route.ts. Sera revogada
-- em F0-02, junto com a troca dessas rotas para a chave secreta.
--
-- ATENCAO: esta migracao sozinha NAO fecha o acesso. Ver 20260817140100 (F0-01b):
-- CREATE FUNCTION concede EXECUTE a PUBLIC por padrao, e anon/authenticated
-- herdam desse grant. O revoke nominal abaixo e necessario, mas insuficiente.

revoke execute on function public.site_list_calendar_connections_for_sync(target_site_project_id text, target_email text, target_tenant_id uuid) from anon, authenticated;

revoke execute on function public.site_save_calendar_connection(target_site_project_id text, target_email text, target_tenant_id uuid, target_provider text, target_member_name text, target_external_account_email text, target_calendar_id text, target_access_token text, target_refresh_token text, target_token_expires_at timestamp with time zone, target_scope text) from anon, authenticated;

revoke execute on function public.site_record_calendar_shift_sync(target_site_project_id text, target_email text, target_tenant_id uuid, target_connection_id uuid, target_window_start timestamp with time zone, target_window_end timestamp with time zone, target_events jsonb, target_new_access_token text, target_new_token_expires_at timestamp with time zone, target_error text) from anon, authenticated;

revoke execute on function public.site_disconnect_calendar_connection(target_site_project_id text, target_email text, target_tenant_id uuid, target_connection_id uuid) from anon, authenticated;

revoke execute on function public.site_list_calendar_connections(target_site_project_id text, target_email text, target_tenant_id uuid) from anon, authenticated;

revoke execute on function public.site_list_calendar_shifts(target_site_project_id text, target_email text, target_tenant_id uuid) from anon, authenticated;

revoke execute on function public.site_start_new_draft(target_site_project_id text, target_email text, target_tenant_id uuid, target_correlation_id text) from anon, authenticated;

revoke execute on function public.schedule_list_calendar_shifts(target_site_project_id text, target_email text, target_tenant_id uuid, target_unit_id uuid) from anon, authenticated;

revoke execute on function public.schedule_list_strand_test_occupancies(target_site_project_id text, target_email text, target_tenant_id uuid, target_unit_id uuid) from anon, authenticated;

revoke execute on function public.schedule_record_strand_test_booking(target_site_project_id text, target_email text, target_tenant_id uuid, target_unit_id uuid, target_main_appointment_id uuid, target_member_id uuid, target_member_name text, target_resource_id uuid, target_starts_at timestamp with time zone, target_ends_at timestamp with time zone, target_correlation_id text) from anon, authenticated;
