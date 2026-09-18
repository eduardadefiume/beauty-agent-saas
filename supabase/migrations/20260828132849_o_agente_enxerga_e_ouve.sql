-- O agente enxerga imagem e ouve áudio.
--
-- O QUE ACONTECEU HOJE. A cliente mandou o card de promoção do salão — com
-- preço, o que está incluso e a regra do teste, tudo escrito na imagem — e o
-- agente respondeu como se tivesse recebido um envelope fechado. Ele parou e
-- perguntou à dona se existia promoção. A pergunta estava certa dado o que ele
-- sabia; o problema é que a resposta estava na tela e ele não podia ver.
--
-- E o histórico é pior que isso: 49 de 355 conversas do salão não têm UMA LINHA
-- escrita. São só áudio. Um agente que não ouve está cego em um sétimo das
-- conversas e mudo no resto delas.
--
-- COMO FUNCIONA. Um worker pega mensagens de mídia ainda não interpretadas,
-- baixa o arquivo da Meta, e transforma em texto: imagem vira descrição do que
-- está escrito e do que aparece; áudio vira transcrição. O texto fica na
-- mensagem; o arquivo é descartado. É a mesma regra de sempre — guardamos o
-- resultado, não a foto da cliente.
--
-- A GUARDA QUE IMPORTA. Enquanto a mídia não estiver interpretada, a conversa
-- NÃO entra na fila do agente. Sem isso ele responde no escuro, que foi
-- exatamente o que aconteceu hoje. Com teto: depois de três tentativas ou dez
-- minutos, a conversa segue mesmo sem interpretação — melhor um agente que
-- pergunta do que uma cliente esperando para sempre.

alter table app.crm_messages
  add column if not exists media_understanding text,
  add column if not exists media_understood_at timestamptz,
  add column if not exists media_attempts integer not null default 0,
  add column if not exists media_error text;

comment on column app.crm_messages.media_understanding is
  'O que a imagem mostra ou o que o audio diz, em texto. O arquivo nao e guardado -- fica so isto.';
comment on column app.crm_messages.media_attempts is
  'Tentativas de interpretar. Existe para a conversa nao ficar presa para sempre quando a midia falha.';

-- Fila do leitor de mídia. Só mensagens recebidas, só de mídia, só as que
-- ainda não foram lidas e ainda têm tentativa sobrando.
create or replace function public.list_media_awaiting_reading(p_limit integer default 5)
returns table (
  message_id uuid,
  tenant_id uuid,
  conversation_id uuid,
  inbox_event_id uuid,
  event_type text,
  caption text,
  attempts integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  select m.id, m.tenant_id, m.conversation_id,
         (m.metadata_minimized->>'inboxEventId')::uuid,
         m.metadata_minimized->>'eventType',
         m.body_text,
         m.media_attempts
    from app.crm_messages m
   where m.direction = 'INBOUND'
     and m.message_type = 'MEDIA'
     and m.media_understanding is null
     and m.media_attempts < 3
     and m.metadata_minimized ? 'inboxEventId'
     -- Mídia velha não vale a chamada: a Meta descarta o arquivo depois de
     -- um tempo, e conversa de ontem já foi resolvida por gente.
     and m.occurred_at > statement_timestamp() - interval '24 hours'
   order by m.occurred_at
   limit greatest(least(coalesce(p_limit, 5), 20), 1);
$function$;

revoke all on function public.list_media_awaiting_reading(integer) from public, anon, authenticated;
grant execute on function public.list_media_awaiting_reading(integer) to service_role;

-- Onde o leitor devolve o id da mídia guardado no evento cru.
create or replace function public.media_id_for_message(p_message_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
           'mediaId', e.payload #>> '{message,image,id}',
           'audioId', e.payload #>> '{message,audio,id}',
           'videoId', e.payload #>> '{message,video,id}',
           'documentId', e.payload #>> '{message,document,id}',
           'mimeType', coalesce(
             e.payload #>> '{message,image,mime_type}',
             e.payload #>> '{message,audio,mime_type}',
             e.payload #>> '{message,video,mime_type}',
             e.payload #>> '{message,document,mime_type}')
         )
    from app.crm_messages m
    join app.inbox_events e on e.id = (m.metadata_minimized->>'inboxEventId')::uuid
   where m.id = p_message_id;
$function$;

revoke all on function public.media_id_for_message(uuid) from public, anon, authenticated;
grant execute on function public.media_id_for_message(uuid) to service_role;

create or replace function public.record_media_understanding(
  p_message_id uuid,
  p_understanding text,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  update app.crm_messages
     set media_attempts = media_attempts + 1,
         media_understanding = case
           when coalesce(trim(p_understanding), '') <> '' then left(p_understanding, 4000)
           else media_understanding end,
         media_understood_at = case
           when coalesce(trim(p_understanding), '') <> '' then statement_timestamp()
           else media_understood_at end,
         media_error = p_error
   where id = p_message_id;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'MESSAGE_NOT_FOUND');
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.record_media_understanding(uuid, text, text) from public, anon, authenticated;
grant execute on function public.record_media_understanding(uuid, text, text) to service_role;
