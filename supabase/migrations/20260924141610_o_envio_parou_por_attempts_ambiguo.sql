-- O ENVIO PAROU POR DOIS MINUTOS: "attempts" AMBIGUO.
--
-- 24/09/2026, 14:14. 20260924141224 acrescentou ao claim_outbox_batch um
-- update sem alias, e `attempts` casou com a coluna de saida da propria funcao
-- (RETURNS TABLE). Todo tick do envio devolveu 42702 e nenhuma mensagem saiu,
-- de salao nenhum. O conserto e so o alias; o resto da funcao nao muda.
--
-- LICAO: em plpgsql com RETURNS TABLE, toda coluna em SQL dentro do corpo leva
-- alias. O resto desta mesma funcao ja fazia isso -- por esse motivo.

create or replace function app.claim_outbox_batch(p_limit integer default 20)
 returns table(id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text, body_text text, attempts integer, media_storage_path text, media_mime_type text, media_filename text, media_provider_id text, credential_ref text, connection_id uuid, template_name text, template_language text, template_params jsonb)
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_simulada uuid;
begin
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'p_limit deve estar entre 1 e 200, recebido %', p_limit;
  end if;

  -- Canal simulado nao sai daqui: a mensagem vira SENT sem tocar a Meta, pelo
  -- mesmo mark_outbox_result que o envio de verdade usa.
  for v_simulada in
    select o.id
      from app.outbox_messages o
      join app.channel_connections c on c.id = o.channel_connection_id
     where o.status = 'PENDING' and c.simulado
     for update of o skip locked
  loop
    update app.outbox_messages o
       set status = 'SENDING', attempts = o.attempts + 1,
           updated_at = statement_timestamp()
     where o.id = v_simulada;
    perform app.mark_outbox_result(v_simulada, true, 'simulado:' || v_simulada::text, null);
  end loop;

  return query
  with reservados as (
    select o.id
      from app.outbox_messages o
     where o.status = 'PENDING'
       and o.next_attempt_at <= statement_timestamp()
     order by o.next_attempt_at, o.created_at, o.id
     limit p_limit
       for update skip locked
  ),
  atualizados as (
    update app.outbox_messages o
       set status = 'SENDING',
           attempts = o.attempts + 1,
           updated_at = statement_timestamp()
      from reservados r
     where o.id = r.id
    returning o.id, o.tenant_id, o.channel_connection_id,
              o.recipient_address, o.kind, o.body_text, o.attempts,
              o.media_storage_path, o.media_mime_type, o.media_filename,
              o.media_provider_id, o.created_at,
              o.template_name, o.template_language, o.template_params
  )
  select a.id, a.tenant_id, c.external_sender_id,
         a.recipient_address, a.kind, a.body_text, a.attempts,
         a.media_storage_path, a.media_mime_type, a.media_filename,
         a.media_provider_id, c.credential_ref, c.id,
         a.template_name, a.template_language, a.template_params
    from atualizados a
    left join app.channel_connections c on c.id = a.channel_connection_id
   order by a.created_at, a.id;
end;
$function$;

revoke all on function app.claim_outbox_batch(integer) from public, anon, authenticated;
