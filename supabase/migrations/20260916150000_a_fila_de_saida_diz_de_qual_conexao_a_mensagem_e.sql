-- A FILA DE SAIDA DIZ DE QUAL CONEXAO A MENSAGEM E.
--
-- O `credential_ref` sozinho resolvia duas formas: variavel de ambiente e
-- padrao. A terceira -- o token cifrado na propria conexao, que e como todo
-- salao novo vai chegar -- precisa saber QUAL conexao, e isso a fila nao
-- devolvia.
--
-- E a porta em `public` vai na MESMA migracao. Ontem eu troquei o retorno
-- desta funcao e esqueci a porta: o Postgres nao reclama ao criar, reclama ao
-- chamar, e como todo envio passa por aqui o WhatsApp do salao ficou vinte
-- minutos sem mandar mensagem. Duas assinaturas escritas a mao que precisam
-- concordar mudam juntas, sempre.

drop function if exists public.claim_outbox_batch(integer);
drop function if exists app.claim_outbox_batch(integer);

create function app.claim_outbox_batch(p_limit integer default 20)
returns table(
  id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text,
  body_text text, attempts integer, media_storage_path text, media_mime_type text,
  media_filename text, media_provider_id text, credential_ref text, connection_id uuid
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
         a.media_provider_id, c.credential_ref, c.id
    from atualizados a
    left join app.channel_connections c on c.id = a.channel_connection_id
   -- Sem esta linha, a conversa sai fora de ordem de vez em quando.
   order by a.created_at, a.id;
end;
$function$;

create function public.claim_outbox_batch(p_limit integer default 20)
returns table(
  id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text,
  body_text text, attempts integer, media_storage_path text, media_mime_type text,
  media_filename text, media_provider_id text, credential_ref text, connection_id uuid
)
language sql
security definer
set search_path to ''
as $function$
  select * from app.claim_outbox_batch(p_limit);
$function$;

revoke all on function app.claim_outbox_batch(integer) from public, anon, authenticated;
revoke all on function public.claim_outbox_batch(integer) from public, anon, authenticated;
grant execute on function public.claim_outbox_batch(integer) to service_role;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- A guarda de dono, para quem vai falar com a Meta em nome do salao
--
-- Conectar o WhatsApp nao e leitura nem escrita de configuracao: e trocar um
-- codigo por um token que passa a falar pelo numero do salao. Antes disso o
-- banco confere que quem pediu e dono ou administrador DAQUELE salao -- o
-- cracha do site sozinho diz quem e a pessoa, nao de qual salao ela manda.
-- ---------------------------------------------------------------------------
create or replace function public.site_assert_owner(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.site_assert_owner(text, text, uuid) from public, anon, authenticated;
grant execute on function public.site_assert_owner(text, text, uuid) to service_role;
