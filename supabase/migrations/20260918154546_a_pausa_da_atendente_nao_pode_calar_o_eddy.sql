-- A PAUSA DA ATENDENTE NAO PODE CALAR O EDDY.
--
-- 18/09/2026, 15:18. A dona escreveu "Ola Eddy" duas vezes e nao recebeu nada.
-- O Eddy tinha trabalhado: decidiu REPLY nas duas, com motivo escrito
-- ("Retomando pergunta pendente sobre tolerancia de atraso"), e marcou as duas
-- mensagens como decididas. Nada chegou.
--
-- A saida morreu aqui dentro:
--
--   if p_actor = 'AGENT' and not app.agent_automation_enabled(p_tenant_id) then
--     return ... 'AGENT_AUTOMATION_DISABLED'
--
-- O Eddy enfileira como 'AGENT', e a automacao estava desligada desde as 9h --
-- desligada de proposito, para a ATENDENTE nao falar com cliente real enquanto
-- a configuracao e refeita.
--
-- O interruptor governa ATENDIMENTO A CLIENTE. Ele nunca quis dizer nada sobre
-- a conversa do dono configurando o proprio salao. A fila do Eddy ja sabia
-- disso (list_owner_conversations_awaiting_eddy nao consulta o interruptor); a
-- porta de saida e que nao sabia.
--
-- O estrago desse desencontro e pior que silencio: o Eddy acorda, gasta chamada
-- de modelo, decide, MARCA a mensagem como decidida -- e a fila exclui o que ja
-- foi decidido. Ou seja, a mensagem do dono fica perdida para sempre, e ninguem
-- e avisado. Silencio que custa dinheiro e nao volta.
--
-- O conserto e uma condicao a mais, nao um afrouxamento: continua valendo que
-- agente nao fala com CLIENTE quando a automacao esta desligada.

create or replace function app.enqueue_outbound_message(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_body_text text,
  p_actor app.outbound_actor,
  p_idempotency_key text,
  p_actor_user_id uuid default null::uuid,
  p_media_storage_path text default null::text,
  p_media_mime_type text default null::text,
  p_media_filename text default null::text
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
  if not v_tem_midia and (p_body_text is null or length(trim(p_body_text)) = 0) then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_BODY');
  end if;
  if v_tem_midia and coalesce(trim(p_media_mime_type), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'MEDIA_MIME_REQUIRED');
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 8 and 128 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_IDEMPOTENCY_KEY');
  end if;

  -- A UNICA MUDANCA: o interruptor vale para conversa de CLIENTE.
  -- Conversa do dono configurando o proprio salao nunca foi assunto dele.
  if p_actor = 'AGENT'
     and not app.agent_automation_enabled(p_tenant_id)
     and not app.conversa_e_do_dono(p_conversation_id) then
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

-- As duas mensagens dela de hoje ficaram marcadas como decididas, e a fila
-- exclui decidida. Sem isto, ela teria que escrever de novo sem entender por
-- que a primeira sumiu. Tira a marca so das duas, so nesta conversa, so de
-- hoje -- nada de limpar decisao em lote.
update app.crm_messages m
   set metadata_minimized = m.metadata_minimized - 'agentDecision'
                                                 - 'agentDecisionReason'
                                                 - 'agentDecidedAt'
 where m.direction = 'INBOUND'
   and m.occurred_at > statement_timestamp() - interval '2 hours'
   and app.conversa_e_do_dono(m.conversation_id)
   and m.metadata_minimized->>'agentDecision' = 'REPLY'
   and not exists (
     select 1 from app.outbox_messages o
      where o.conversation_id = m.conversation_id
        and o.created_at > m.occurred_at
   );
