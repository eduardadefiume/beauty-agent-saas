create or replace function public.ingest_whatsapp_webhook(
  p_waba_id text,
  p_phone_number_id text,
  p_payload_sha256 text,
  p_correlation_id text,
  p_events jsonb
)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, api
as $$
  select api.ingest_whatsapp_webhook($1, $2, $3, $4, $5);
$$;

revoke all on function public.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  from public, anon, authenticated;

grant execute on function public.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  to service_role;

comment on function public.ingest_whatsapp_webhook(text, text, text, text, jsonb) is
  'Service-role-only PostgREST gateway for the WhatsApp webhook ingestion RPC.';