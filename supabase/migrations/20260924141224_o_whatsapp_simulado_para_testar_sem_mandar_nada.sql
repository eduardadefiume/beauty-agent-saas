-- O WHATSAPP SIMULADO, PARA TESTAR SEM MANDAR NADA.
--
-- 24/09/2026. Ate hoje o unico jeito de ver o Eddy e a atendente trabalhando
-- era a dona pegar o celular e mandar mensagem. Cada teste custava o tempo
-- dela, e cada bug era descoberto por ela. Este arquivo cria um canal que
-- passa pela MESMA corrente de ponta a ponta -- ingest, projecao, leitura de
-- midia, agente, outbox -- e so desvia no ultimo metro: a mensagem de saida e
-- marcada como enviada sem ir para a Meta.
--
--   channel_connections.simulado   a marca. So canal simulado aceita mensagem
--                                  forjada, e so ele deixa de ir para a Meta.
--   app.simular_whatsapp           injeta uma mensagem como se a Meta tivesse
--                                  entregue: texto, foto (lida de verdade, do
--                                  balde), audio (com a transcricao dada) ou
--                                  video.
--   claim_outbox_batch             entrega o que e de canal simulado antes de
--                                  reservar o resto.
--   media_id_for_message           devolve o caminho da foto no balde e a
--                                  transcricao simulada, para o leitor de midia.

alter table app.channel_connections
  add column if not exists simulado boolean not null default false;

comment on column app.channel_connections.simulado is
  'Canal de teste: aceita mensagem forjada por app.simular_whatsapp e nunca chama a Meta.';

create or replace function app.simular_whatsapp(
  p_connection_id uuid,
  p_de text,
  p_tipo text default 'text',
  p_texto text default null,
  p_caminho_da_midia text default null,
  p_transcricao text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_conexao app.channel_connections%rowtype;
  v_de text := regexp_replace(coalesce(p_de, ''), '[^0-9]', '', 'g');
  v_tipo text := lower(trim(coalesce(p_tipo, 'text')));
  v_id text := 'wamid.SIMULADO.' || replace(gen_random_uuid()::text, '-', '');
  v_mensagem jsonb;
  v_resultado jsonb;
begin
  select * into v_conexao from app.channel_connections where id = p_connection_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'CONEXAO_NAO_EXISTE');
  end if;
  -- A trava inteira do arquivo: forjar mensagem em canal de verdade seria
  -- falar em nome de uma cliente real.
  if not v_conexao.simulado then
    return jsonb_build_object('ok', false, 'reason', 'CONEXAO_NAO_E_SIMULADA');
  end if;
  if length(v_de) < 10 then
    return jsonb_build_object('ok', false, 'reason', 'NUMERO_INVALIDO');
  end if;

  v_mensagem := jsonb_build_object(
    'id', v_id,
    'from', v_de,
    'type', v_tipo,
    'timestamp', extract(epoch from statement_timestamp())::bigint::text
  );

  if v_tipo = 'text' then
    if coalesce(trim(p_texto), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'TEXTO_VAZIO');
    end if;
    v_mensagem := v_mensagem || jsonb_build_object('text', jsonb_build_object('body', p_texto));
  elsif v_tipo = 'image' then
    if p_caminho_da_midia is null then
      return jsonb_build_object('ok', false, 'reason', 'FOTO_SEM_CAMINHO');
    end if;
    v_mensagem := v_mensagem || jsonb_build_object('image', jsonb_strip_nulls(jsonb_build_object(
      'id', 'simulado-' || v_id,
      'mime_type', case when p_caminho_da_midia ~* '\.png$' then 'image/png' else 'image/jpeg' end,
      'caption', nullif(trim(coalesce(p_texto, '')), ''),
      'simulado_caminho', p_caminho_da_midia)));
  elsif v_tipo = 'audio' then
    if coalesce(trim(p_transcricao), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'AUDIO_SEM_TRANSCRICAO');
    end if;
    v_mensagem := v_mensagem || jsonb_build_object('audio', jsonb_build_object(
      'id', 'simulado-' || v_id, 'mime_type', 'audio/ogg; codecs=opus', 'voice', true,
      'simulado_transcricao', p_transcricao));
  elsif v_tipo = 'video' then
    v_mensagem := v_mensagem || jsonb_build_object('video', jsonb_strip_nulls(jsonb_build_object(
      'id', 'simulado-' || v_id, 'mime_type', 'video/mp4',
      'caption', nullif(trim(coalesce(p_texto, '')), ''))));
  else
    return jsonb_build_object('ok', false, 'reason', 'TIPO_NAO_SIMULADO');
  end if;

  v_resultado := api.ingest_whatsapp_webhook(
    v_conexao.external_account_id,
    v_conexao.external_sender_id,
    encode(extensions.digest(v_id, 'sha256'), 'hex'),
    'simulado-' || left(replace(gen_random_uuid()::text, '-', ''), 24),
    jsonb_build_array(jsonb_build_object(
      'externalEventId', 'message:' || v_id,
      'eventType', 'WHATSAPP_MESSAGE_' || upper(v_tipo),
      'contact', v_de,
      'payload', jsonb_build_object(
        'field', 'messages',
        'object', 'whatsapp_business_account',
        'entryId', v_conexao.external_account_id,
        'metadata', jsonb_build_object(
          'phone_number_id', v_conexao.external_sender_id,
          'display_phone_number', regexp_replace(coalesce(v_conexao.display_phone_number, ''), '[^0-9]', '', 'g')),
        'message', v_mensagem)))
  );

  return jsonb_build_object('ok', true, 'wamid', v_id, 'ingest', v_resultado);
end;
$fn$;

revoke all on function app.simular_whatsapp(uuid, text, text, text, text, text) from public, anon, authenticated;

create or replace function public.simular_whatsapp(
  p_connection_id uuid, p_de text, p_tipo text default 'text', p_texto text default null,
  p_caminho_da_midia text default null, p_transcricao text default null
)
returns jsonb language sql security definer set search_path to ''
as $$ select app.simular_whatsapp(p_connection_id, p_de, p_tipo, p_texto, p_caminho_da_midia, p_transcricao); $$;

revoke all on function public.simular_whatsapp(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.simular_whatsapp(uuid, text, text, text, text, text) to service_role;

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
    update app.outbox_messages set status = 'SENDING', attempts = attempts + 1,
           updated_at = statement_timestamp()
     where outbox_messages.id = v_simulada;
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

create or replace function public.media_id_for_message(p_message_id uuid)
 returns jsonb
 language sql
 stable security definer
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
             e.payload #>> '{message,document,mime_type}'),
           -- So existem em mensagem de canal simulado: o ingest de verdade
           -- nunca recebe estas chaves da Meta.
           'caminhoSimulado', case when c.simulado then e.payload #>> '{message,image,simulado_caminho}' end,
           'transcricaoSimulada', case when c.simulado then e.payload #>> '{message,audio,simulado_transcricao}' end
         )
    from app.crm_messages m
    join app.inbox_events e on e.id = (m.metadata_minimized->>'inboxEventId')::uuid
    join app.channel_connections c on c.id = e.connection_id
   where m.id = p_message_id;
$function$;

revoke all on function public.media_id_for_message(uuid) from public, anon, authenticated;
grant execute on function public.media_id_for_message(uuid) to service_role;
