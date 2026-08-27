-- Enfileirar mídia pelo mesmo caminho do texto.
--
-- A função ganha três parâmetros opcionais de mídia em vez de existir uma
-- segunda função só para anexo. Foto com legenda e texto puro são a mesma
-- mensagem numa conversa; duplicar a função duplicaria também as guardas --
-- janela de 24h, parada de emergência, idempotência -- e guarda duplicada é
-- guarda que um dia diverge.
--
-- A versão antiga de 6 argumentos é derrubada de propósito. Deixar as duas
-- conviverem faria a chamada posicional do wrapper público escolher uma delas
-- por sorte da resolução de tipos.
--
-- A regra do corpo vazio muda: texto sem corpo continua sendo recusado, mas
-- mídia sem legenda é legítima -- ninguém escreve nada ao mandar um áudio.

drop function if exists app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid);

create or replace function app.enqueue_outbound_message(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_body_text text,
  p_actor app.outbound_actor,
  p_idempotency_key text,
  p_actor_user_id uuid default null,
  p_media_storage_path text default null,
  p_media_mime_type text default null,
  p_media_filename text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_conversa record;
  v_endereco text;
  v_janela_aberta boolean;
  v_message_id uuid;
  v_outbox_id uuid;
  v_existente record;
  v_tem_midia boolean := coalesce(trim(p_media_storage_path), '') <> '';
  v_tipo text;
begin
  -- Mídia sem legenda é legítima. Texto sem corpo não é.
  if not v_tem_midia and (p_body_text is null or length(trim(p_body_text)) = 0) then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_BODY');
  end if;
  if v_tem_midia and coalesce(trim(p_media_mime_type), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'MEDIA_MIME_REQUIRED');
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 8 and 128 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_IDEMPOTENCY_KEY');
  end if;

  -- Só o agente é barrado. Envio humano passa com a chave desligada -- é o
  -- ponto todo: a parada de emergência cala o robô, não o salão.
  if p_actor = 'AGENT' and not app.agent_automation_enabled(p_tenant_id) then
    return jsonb_build_object('ok', false, 'reason', 'AGENT_AUTOMATION_DISABLED');
  end if;

  select o.id, o.message_id, o.status into v_existente
    from app.outbox_messages o
   where o.tenant_id = p_tenant_id
     and o.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'ok', true, 'duplicate', true,
      'outboxId', v_existente.id, 'messageId', v_existente.message_id,
      'status', v_existente.status
    );
  end if;

  select c.*, ch.address_normalized
    into v_conversa
    from app.crm_conversations c
    join app.crm_contact_channels ch
      on ch.tenant_id = c.tenant_id
     and ch.contact_id = c.contact_id
     and ch.provider = 'WHATSAPP'
   where c.tenant_id = p_tenant_id
     and c.id = p_conversation_id
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSATION_NOT_FOUND');
  end if;

  v_endereco := v_conversa.address_normalized;

  v_janela_aberta := v_conversa.last_inbound_at is not null
    and v_conversa.last_inbound_at > (statement_timestamp() - interval '24 hours');

  if not v_janela_aberta then
    return jsonb_build_object(
      'ok', false,
      'reason', 'SERVICE_WINDOW_CLOSED',
      'lastInboundAt', v_conversa.last_inbound_at,
      'hint', 'Fora da janela de 24h so e possivel reabrir com template aprovado.'
    );
  end if;

  v_tipo := case when v_tem_midia then 'MEDIA' else 'TEXT' end;

  insert into app.crm_messages (
    tenant_id, conversation_id, direction, provider_message_id,
    message_type, body_text, occurred_at, metadata_minimized
  )
  values (
    p_tenant_id, p_conversation_id, 'OUTBOUND', null,
    v_tipo, left(p_body_text, 4096), statement_timestamp(),
    jsonb_strip_nulls(jsonb_build_object(
      'actor', p_actor,
      'deliveryStatus', 'PENDING',
      'mediaMimeType', nullif(trim(coalesce(p_media_mime_type, '')), ''),
      'mediaFilename', nullif(trim(coalesce(p_media_filename, '')), ''),
      'mediaStoragePath', nullif(trim(coalesce(p_media_storage_path, '')), '')
    ))
  )
  returning id into v_message_id;

  insert into app.outbox_messages (
    tenant_id, conversation_id, message_id, channel_connection_id,
    recipient_address, kind, body_text, actor, actor_user_id, idempotency_key,
    media_storage_path, media_mime_type, media_filename
  )
  values (
    p_tenant_id, p_conversation_id, v_message_id, v_conversa.channel_connection_id,
    v_endereco, v_tipo, left(p_body_text, 4096), p_actor, p_actor_user_id,
    trim(p_idempotency_key),
    nullif(trim(coalesce(p_media_storage_path, '')), ''),
    nullif(trim(coalesce(p_media_mime_type, '')), ''),
    nullif(trim(coalesce(p_media_filename, '')), '')
  )
  returning id into v_outbox_id;

  update app.crm_conversations
     set last_message_at = greatest(last_message_at, statement_timestamp()),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id and id = p_conversation_id;

  return jsonb_build_object(
    'ok', true, 'duplicate', false,
    'outboxId', v_outbox_id, 'messageId', v_message_id, 'recipient', v_endereco
  );
end;
$function$;

-- A porta que a tela usa, agora aceitando anexo.
create or replace function public.site_send_manual_message(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_conversation_id uuid,
  message_text           text,
  idempotency_key        text,
  media_storage_path     text default null,
  media_mime_type        text default null,
  media_filename         text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  if coalesce(length(message_text), 0) > 4096 then
    return jsonb_build_object('ok', false, 'reason', 'BODY_TOO_LONG');
  end if;

  -- O caminho tem que começar pela pasta do próprio salão. Sem isto, um
  -- caminho inventado no navegador faria o worker buscar arquivo de outro
  -- tenant -- as políticas do balde protegem o navegador, não o servidor, que
  -- baixa com a chave de serviço.
  if coalesce(trim(media_storage_path), '') <> ''
     and media_storage_path not like target_tenant_id::text || '/%' then
    return jsonb_build_object('ok', false, 'reason', 'MEDIA_PATH_FORBIDDEN');
  end if;

  return app.enqueue_outbound_message(
    p_tenant_id          => target_tenant_id,
    p_conversation_id    => target_conversation_id,
    p_body_text          => message_text,
    p_actor              => 'HUMAN'::app.outbound_actor,
    p_idempotency_key    => idempotency_key,
    p_media_storage_path => media_storage_path,
    p_media_mime_type    => media_mime_type,
    p_media_filename     => media_filename
  );
end;
$function$;

drop function if exists public.site_send_manual_message(text, text, uuid, uuid, text, text);

revoke all on function public.site_send_manual_message(text, text, uuid, uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.site_send_manual_message(text, text, uuid, uuid, text, text, text, text, text)
  to service_role;
