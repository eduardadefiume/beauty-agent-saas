-- AS PORTAS DO EDDY NO SCHEMA PUBLICO.
--
-- A edge function fala com o banco pelo PostgREST, e o PostgREST so enxerga o
-- schema `public`. Todas as funcoes do Eddy nasceram em `app` -- que e onde
-- elas tem que morar -- e nenhuma ganhou a porta correspondente. O primeiro
-- disparo do worker devolveu, honestamente:
--
--   PGRST202: Could not find the function
--   public.list_owner_conversations_awaiting_eddy in the schema cache
--
-- Cada porta e uma linha: recebe, repassa, e nao decide nada. Quem decide
-- continua em `app`, e e la que a regra fica.
--
-- `agent_prompt` ganha a porta COM argumento, e a sem argumento continua
-- existindo do lado dela. Nao e duplicacao: o PostgREST escolhe pelo nome do
-- parametro -- `{}` cai na de cliente, `{"p_agent":"DONO"}` cai na do dono --
-- e sem default na porta nova nenhuma chamada em SQL fica ambigua.

create or replace function public.agent_prompt(p_agent text)
returns text language sql stable security definer set search_path to ''
as $function$ select app.agent_prompt(p_agent); $function$;

create or replace function public.list_owner_conversations_awaiting_eddy(
  p_limit integer default 10,
  p_quiet_seconds integer default 25
)
returns table(
  conversation_id uuid, tenant_id uuid, last_inbound_message_id uuid, waiting_seconds integer
)
language sql stable security definer set search_path to ''
as $function$
  select * from app.list_owner_conversations_awaiting_eddy(p_limit, p_quiet_seconds);
$function$;

create or replace function public.build_owner_context(
  p_conversation_id uuid,
  p_history_limit integer default 20
)
returns jsonb language sql stable security definer set search_path to ''
as $function$ select app.build_owner_context(p_conversation_id, p_history_limit); $function$;

create or replace function public.onboarding_pendencies(p_tenant_id uuid)
returns table(modulo text, chave text, pergunta text, contexto text, prioridade integer)
language sql stable security definer set search_path to ''
as $function$ select * from app.onboarding_pendencies(p_tenant_id); $function$;

create or replace function public.eddy_sessao(p_tenant_id uuid)
returns uuid language sql security definer set search_path to ''
as $function$ select app.eddy_sessao(p_tenant_id); $function$;

create or replace function public.eddy_turno(
  p_tenant_id uuid, p_session_id uuid, p_quem text, p_texto text
)
returns uuid language sql security definer set search_path to ''
as $function$ select app.eddy_turno(p_tenant_id, p_session_id, p_quem, p_texto); $function$;

create or replace function public.onboarding_record_answer(
  p_session_id uuid, p_turn_id uuid, p_key text, p_modulo text,
  p_entendido text, p_valor_texto text, p_valor_numero numeric, p_confidence numeric
)
returns jsonb language sql security definer set search_path to ''
as $function$
  select app.onboarding_record_answer(
    p_session_id, p_turn_id, p_key, p_modulo,
    p_entendido, p_valor_texto, p_valor_numero, p_confidence
  );
$function$;

-- Porta de servico e do worker, e de mais ninguem. O `anon` e publico: ele
-- viaja no JavaScript do site.
revoke all on function public.agent_prompt(text) from public, anon, authenticated;
revoke all on function public.list_owner_conversations_awaiting_eddy(integer, integer) from public, anon, authenticated;
revoke all on function public.build_owner_context(uuid, integer) from public, anon, authenticated;
revoke all on function public.onboarding_pendencies(uuid) from public, anon, authenticated;
revoke all on function public.eddy_sessao(uuid) from public, anon, authenticated;
revoke all on function public.eddy_turno(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.onboarding_record_answer(uuid, uuid, text, text, text, text, numeric, numeric) from public, anon, authenticated;

grant execute on function public.agent_prompt(text) to service_role;
grant execute on function public.list_owner_conversations_awaiting_eddy(integer, integer) to service_role;
grant execute on function public.build_owner_context(uuid, integer) to service_role;
grant execute on function public.onboarding_pendencies(uuid) to service_role;
grant execute on function public.eddy_sessao(uuid) to service_role;
grant execute on function public.eddy_turno(uuid, uuid, text, text) to service_role;
grant execute on function public.onboarding_record_answer(uuid, uuid, text, text, text, text, numeric, numeric) to service_role;

notify pgrst, 'reload schema';
