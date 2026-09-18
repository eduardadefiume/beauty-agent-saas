drop function if exists api.claim_outbox_batch(integer);
drop function if exists api.mark_outbox_result(uuid, boolean, text, text);

create or replace function public.claim_outbox_batch(p_limit integer default 20)
returns table (
  id uuid,
  tenant_id uuid,
  sender_id text,
  recipient_address text,
  kind text,
  body_text text,
  attempts integer
)
language sql
security definer
set search_path to ''
as $function$
  select * from app.claim_outbox_batch(p_limit);
$function$;

create or replace function public.mark_outbox_result(
  p_outbox_id uuid,
  p_success boolean,
  p_provider_message_id text default null,
  p_error text default null
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select app.mark_outbox_result(p_outbox_id, p_success, p_provider_message_id, p_error);
$function$;

revoke all on function public.claim_outbox_batch(integer) from public, anon, authenticated;
grant execute on function public.claim_outbox_batch(integer) to service_role;

revoke all on function public.mark_outbox_result(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.mark_outbox_result(uuid, boolean, text, text) to service_role;

comment on function public.claim_outbox_batch(integer) is
  'Fachada HTTP para app.claim_outbox_batch. O PostgREST so expoe public; a logica continua em app.';
comment on function public.mark_outbox_result(uuid, boolean, text, text) is
  'Fachada HTTP para app.mark_outbox_result. Mesma razao da funcao irma.';