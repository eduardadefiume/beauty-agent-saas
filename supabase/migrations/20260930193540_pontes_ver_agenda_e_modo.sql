-- PONTES NO PUBLIC.
--
-- As edge functions chamam o PostgREST, que só enxerga o schema public. Sem a
-- ponte, eddy_ver_agenda dava 404 e o Eddy respondeu ao dono "não consigo
-- fazer isso por aqui" (30/09, 19:20). E a ponte do modo da equipe precisa do
-- parâmetro novo (mostrar quem faz no Google).
create or replace function public.eddy_ver_agenda(p_tenant_id uuid, p_de date, p_ate date)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$ select app.eddy_ver_agenda(p_tenant_id, p_de, p_ate); $function$;

drop function if exists public.eddy_definir_modo_da_equipe(uuid, boolean, text);

create or replace function public.eddy_definir_modo_da_equipe(
  p_tenant_id uuid, p_um_so boolean, p_frente text default null, p_mostrar_quem_faz boolean default null)
 returns jsonb
 language sql
 security definer
 set search_path to ''
as $function$ select app.eddy_definir_modo_da_equipe(p_tenant_id, p_um_so, p_frente, p_mostrar_quem_faz); $function$;

revoke all on function public.eddy_ver_agenda(uuid, date, date) from public, anon, authenticated;
revoke all on function public.eddy_definir_modo_da_equipe(uuid, boolean, text, boolean) from public, anon, authenticated;
grant execute on function public.eddy_ver_agenda(uuid, date, date) to service_role;
grant execute on function public.eddy_definir_modo_da_equipe(uuid, boolean, text, boolean) to service_role;

notify pgrst, 'reload schema';