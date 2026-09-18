-- A ordem das mensagens não pode ser sorteada.
--
-- A cliente recebeu, nesta ordem:
--   "Qual o seu nome?"
--   "Oi, bom dia! Tudo bem sim, e você?"
--
-- O modelo escreveu certo e o banco gravou certo: a primeira mensagem tem
-- idempotency_key terminada em :0 e created_at .597, a segunda :1 e .656.
-- Quem embaralhou foi esta função. Ela ordenava o SELECT que ESCOLHE o lote e
-- devolvia o resultado final sem `order by` nenhum. Sem ordem explícita, o
-- Postgres devolve na ordem que for mais conveniente para ele, e o enviador
-- manda na ordem em que recebe.
--
-- Isso é pior do que parece: não é erro de modelo que se corrige com prompt, e
-- não acontece sempre. Duas mensagens saindo trocadas transformam um
-- atendimento educado em um atendimento estranho, de vez em quando, sem deixar
-- rastro em lugar nenhum.
--
-- A ordem certa é a de criação, não a de próxima tentativa: uma mensagem que
-- falhou e voltou para a fila não pode furar a fila de uma conversa inteira.
create or replace function app.claim_outbox_batch(p_limit integer default 20)
returns table(
  id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text,
  body_text text, attempts integer, media_storage_path text,
  media_mime_type text, media_filename text, media_provider_id text
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
              o.media_provider_id, o.created_at
  )
  select a.id, a.tenant_id, c.external_sender_id,
         a.recipient_address, a.kind, a.body_text, a.attempts,
         a.media_storage_path, a.media_mime_type, a.media_filename,
         a.media_provider_id
    from atualizados a
    left join app.channel_connections c on c.id = a.channel_connection_id
   -- Sem esta linha, a conversa sai fora de ordem de vez em quando.
   order by a.created_at, a.id;
end;
$function$;

comment on function app.claim_outbox_batch(integer) is
  'Reserva o lote de envio. O `order by` do final nao e enfeite: sem ele o Postgres devolve as linhas em ordem arbitraria e as mensagens de uma mesma resposta chegam trocadas para a cliente.';

revoke all on function app.claim_outbox_batch(integer) from public, anon, authenticated;
grant execute on function app.claim_outbox_batch(integer) to service_role;
