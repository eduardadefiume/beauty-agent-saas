-- TRES PORTAS QUE FICARAM ABERTAS.
--
-- 24/09/2026. Varredura no banco de producao: de todas as funcoes SECURITY
-- DEFINER em app/public/api, sete sao executaveis por anon ou authenticated.
-- Quatro de proposito (a lista CHAMAVEIS_POR_USUARIO do guardrail). As tres
-- abaixo nao: nasceram com o EXECUTE padrao de PUBLIC e ninguem revogou.
--
--   app.record_media_understanding  20260916203123
--   app.raise_agent_alert           20260917144958
--   app.aviso_de_espera             20260917144958
--
-- Hoje nao e exploravel -- anon e authenticated nao tem USAGE no schema app --
-- mas a seguranca delas dependia so disso, e o guardrail existe justamente
-- para nao depender de uma camada so.
--
-- Quem chama continua chamando: o worker de midia passa pela fachada
-- public.record_media_understanding (SECURITY DEFINER, dono postgres), e as
-- outras duas sao chamadas de dentro de funcoes SECURITY DEFINER.

revoke all on function app.record_media_understanding(uuid, text, text, text) from public, anon, authenticated;
grant execute on function app.record_media_understanding(uuid, text, text, text) to service_role;

revoke all on function app.raise_agent_alert(uuid, text, text) from public, anon, authenticated;
grant execute on function app.raise_agent_alert(uuid, text, text) to service_role;

revoke all on function app.aviso_de_espera(uuid, uuid, timestamptz) from public, anon, authenticated;
grant execute on function app.aviso_de_espera(uuid, uuid, timestamptz) to service_role;
