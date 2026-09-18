drop function if exists app.claim_outbox_batch(integer);

create function app.claim_outbox_batch(p_limit integer default 20)
returns table (
  id uuid,
  tenant_id uuid,
  sender_id text,
  recipient_address text,
  kind text,
  body_text text,
  attempts integer
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
              o.recipient_address, o.kind, o.body_text, o.attempts
  )
  select a.id, a.tenant_id, c.external_sender_id,
         a.recipient_address, a.kind, a.body_text, a.attempts
    from atualizados a
    left join app.channel_connections c on c.id = a.channel_connection_id;
end;
$function$;

revoke execute on function app.claim_outbox_batch(integer) from public;
revoke all on function app.claim_outbox_batch(integer) from anon, authenticated;
grant execute on function app.claim_outbox_batch(integer) to service_role;