-- A PORTA TAMBEM PRECISAVA SABER DA COLUNA NOVA.
--
-- Eu troquei `app.claim_outbox_batch` para devolver `credential_ref` e nao
-- troquei a porta dela em `public`, que declara as colunas uma a uma. O
-- Postgres nao reclama na hora de criar -- reclama na hora de chamar:
--
--   42P13: return type mismatch in function declared to return record
--   Final statement returns too many columns.
--
-- E como TODO envio passa por essa porta, o WhatsApp do salao parou de mandar
-- mensagem por vinte minutos. A resposta do agente para uma cliente que
-- perguntou preco e as duas primeiras frases do Eddy ficaram paradas em
-- PENDING, com zero tentativa.
--
-- Nada se perdeu, e isso e desenho e nao sorte: a fila so marca SENT depois
-- do "ok" da Meta, e quem falha volta pelo recuo exponencial. Mas ficar
-- calado por vinte minutos e caro com cliente de verdade do outro lado.
--
-- A LICAO, que vale mais que a correcao: funcao em `app` com porta em
-- `public` sao duas assinaturas escritas a mao que precisam concordar. Quando
-- uma muda, a outra muda na MESMA migracao.

drop function if exists public.claim_outbox_batch(integer);

create function public.claim_outbox_batch(p_limit integer default 20)
returns table(
  id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text,
  body_text text, attempts integer, media_storage_path text, media_mime_type text,
  media_filename text, media_provider_id text, credential_ref text
)
language sql
security definer
set search_path to ''
as $function$
  select * from app.claim_outbox_batch(p_limit);
$function$;

revoke all on function public.claim_outbox_batch(integer) from public, anon, authenticated;
grant execute on function public.claim_outbox_batch(integer) to service_role;

notify pgrst, 'reload schema';
