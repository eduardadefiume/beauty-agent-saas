-- A reserva do lote passa a trazer a mídia junto.
--
-- Sem isto o worker recebe a mensagem sem saber que existe um arquivo e a
-- trata como texto vazio. Trocar o tipo de retorno exige derrubar antes --
-- CREATE OR REPLACE não muda assinatura de retorno.
--
-- `media_provider_id` vem no lote de propósito: é o id que a Meta devolve
-- depois do upload. Se a primeira tentativa subiu o arquivo e falhou só no
-- envio da mensagem, a segunda reaproveita o id em vez de subir o mesmo
-- arquivo de novo — o upload é a parte cara e lenta.

drop function if exists public.claim_outbox_batch(integer);
drop function if exists app.claim_outbox_batch(integer);

create or replace function app.claim_outbox_batch(p_limit integer default 20)
returns table (
  id uuid,
  tenant_id uuid,
  sender_id text,
  recipient_address text,
  kind text,
  body_text text,
  attempts integer,
  media_storage_path text,
  media_mime_type text,
  media_filename text,
  media_provider_id text
)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'p_limit deve estar entre 1 e 200, recebido %', p_limit;
  end if;

  return query
  with reservados as (
    select o.id
      from app.outbox_messages o
     where o.status = 'PENDING'
       and o.next_attempt_at <= statement_timestamp()
     order by o.next_attempt_at
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
              o.media_provider_id
  )
  select a.id, a.tenant_id, c.external_sender_id,
         a.recipient_address, a.kind, a.body_text, a.attempts,
         a.media_storage_path, a.media_mime_type, a.media_filename,
         a.media_provider_id
    from atualizados a
    left join app.channel_connections c on c.id = a.channel_connection_id;
end;
$function$;

create or replace function public.claim_outbox_batch(p_limit integer default 20)
returns table (
  id uuid,
  tenant_id uuid,
  sender_id text,
  recipient_address text,
  kind text,
  body_text text,
  attempts integer,
  media_storage_path text,
  media_mime_type text,
  media_filename text,
  media_provider_id text
)
language sql
security definer
set search_path to ''
as $function$
  select * from app.claim_outbox_batch(p_limit);
$function$;

revoke all on function app.claim_outbox_batch(integer) from public, anon, authenticated;
revoke all on function public.claim_outbox_batch(integer) from public, anon, authenticated;
grant execute on function app.claim_outbox_batch(integer) to service_role;
grant execute on function public.claim_outbox_batch(integer) to service_role;

-- Guardar o id da mídia assim que a Meta devolver, ANTES de tentar enviar a
-- mensagem. É o que torna a retentativa barata: subir arquivo de novo custa
-- tempo e banda, e uma mensagem tem até cinco tentativas.
create or replace function public.mark_outbox_media_uploaded(
  p_outbox_id uuid,
  p_media_provider_id text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if coalesce(trim(p_media_provider_id), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_MEDIA_ID');
  end if;

  update app.outbox_messages
     set media_provider_id = trim(p_media_provider_id),
         updated_at = statement_timestamp()
   where id = p_outbox_id;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'OUTBOX_NOT_FOUND');
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.mark_outbox_media_uploaded(uuid, text) from public, anon, authenticated;
grant execute on function public.mark_outbox_media_uploaded(uuid, text) to service_role;
