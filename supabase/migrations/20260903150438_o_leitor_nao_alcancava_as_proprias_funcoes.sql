-- O leitor de histórico não alcançava as próprias funções.
--
-- O SINTOMA: dois `500 Internal Server Error` no `net._http_response`, sem
-- mensagem nenhuma. A fila ficava parada e a tela diria "na fila" para sempre.
--
-- A CAUSA: PostgREST só expõe o schema `public`. `app.wa_archive_claim` e as
-- outras duas nasceram em `app`, então o `POST /rest/v1/rpc/wa_archive_claim`
-- do worker batia em 404, o `rpc()` lançava, e o lance morria fora de qualquer
-- try -- virando 500 sem texto.
--
-- Os outros workers já usavam `public` (list_tone_photos_awaiting_reading,
-- record_tone_photo_level) e eu não olhei antes de escolher o schema. O
-- costume do repositório já tinha a resposta.
--
-- A CORREÇÃO tem duas partes. Aqui, as funções passam a existir em `public`,
-- fechadas para anon e authenticated: quem chama é o crachá de serviço, e
-- estar em `public` é sobre alcance do PostgREST, não sobre permissão.
-- A outra parte é no leitor, que passa a dizer o que falhou em vez de deixar
-- um 500 mudo.

create or replace function public.wa_archive_claim(p_limit integer default 3)
returns table (
  archive_id    uuid,
  tenant_id     uuid,
  storage_path  text,
  filename      text,
  contact_label text,
  owner_label   text
)
language sql
security definer
set search_path to ''
as $function$
  select * from app.wa_archive_claim(p_limit);
$function$;

revoke all on function public.wa_archive_claim(integer) from public, anon, authenticated;
grant execute on function public.wa_archive_claim(integer) to service_role;

create or replace function public.wa_archive_write_chunk(
  p_archive_id uuid,
  p_messages   jsonb
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select app.wa_archive_write_chunk(p_archive_id, p_messages);
$function$;

revoke all on function public.wa_archive_write_chunk(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.wa_archive_write_chunk(uuid, jsonb) to service_role;

create or replace function public.wa_archive_finish(
  p_archive_id uuid,
  p_error      text default null
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select app.wa_archive_finish(p_archive_id, p_error);
$function$;

revoke all on function public.wa_archive_finish(uuid, text) from public, anon, authenticated;
grant execute on function public.wa_archive_finish(uuid, text) to service_role;

-- Os arquivos que tomaram 500 gastaram tentativa sem culpa própria. Voltam
-- para a fila com a contagem zerada: três tentativas queimadas por um erro meu
-- deixariam o arquivo em FALHOU para sempre.
update app.wa_archives
   set status = 'PENDENTE', read_attempts = 0, read_error = null
 where status in ('LENDO', 'FALHOU');
