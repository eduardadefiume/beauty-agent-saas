-- O EDDY SABE SE A ATENDENTE ESTA LIGADA.
--
-- 24/09/2026, teste com dono-robo. Depois de publicar, o Eddy disse "a
-- atendente ja responde e marca com tudo isso a partir de agora" -- e a
-- atendente do salao estava desligada (todo salao nasce desligado). O dono
-- iria esperar clientes sendo atendidas que nao seriam.

create or replace function public.eddy_atendente_ligada(p_tenant_id uuid)
returns boolean language sql stable security definer set search_path to ''
as $$ select app.agent_automation_enabled(p_tenant_id); $$;

revoke all on function public.eddy_atendente_ligada(uuid) from public, anon, authenticated;
grant execute on function public.eddy_atendente_ligada(uuid) to service_role;
