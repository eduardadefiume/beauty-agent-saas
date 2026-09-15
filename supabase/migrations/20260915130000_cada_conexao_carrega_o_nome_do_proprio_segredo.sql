-- CADA CONEXAO CARREGA O NOME DO PROPRIO SEGREDO.
--
-- O numero de teste da Meta que vai ser o Eddy nasce numa WABA propria, e o
-- token do salao nao alcanca ela. Provado no Graph, nao suposto:
--
--   WABA 27715432581451174 (salao) ..... 200, numero CONNECTED, qualidade GREEN
--   WABA 1788651192165822 (teste) ...... code 100, subcode 33, missing permissions
--
-- Com um unico WHATSAPP_ACCESS_TOKEN lido do ambiente, so existe um numero no
-- produto inteiro -- o que tambem seria o teto do SaaS no dia em que o segundo
-- salao entrar com a conta dele.
--
-- `credential_ref` esta na tabela desde o comeco, escrito como
-- `edge-secret:NOME`, e estava sendo ignorado pelo worker. Aqui ele passa a
-- viajar junto com a mensagem reservada; quem nao disser nada continua no
-- WHATSAPP_ACCESS_TOKEN, entao nenhuma conexao ja configurada muda.

-- A coluna nova muda o tipo de retorno, entao o Postgres exige derrubar antes.
-- Derrubar e recriar na MESMA migracao mantem a janela sem funcao dentro de
-- uma transacao so: o worker ou ve a antiga, ou ve a nova, nunca o vazio.
drop function if exists app.claim_outbox_batch(integer);

create function app.claim_outbox_batch(p_limit integer default 20)
returns table(
  id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text,
  body_text text, attempts integer, media_storage_path text, media_mime_type text,
  media_filename text, media_provider_id text, credential_ref text
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
         a.media_provider_id, c.credential_ref
    from atualizados a
    left join app.channel_connections c on c.id = a.channel_connection_id
   -- Sem esta linha, a conversa sai fora de ordem de vez em quando.
   order by a.created_at, a.id;
end;
$function$;

revoke all on function app.claim_outbox_batch(integer) from public, anon, authenticated;
