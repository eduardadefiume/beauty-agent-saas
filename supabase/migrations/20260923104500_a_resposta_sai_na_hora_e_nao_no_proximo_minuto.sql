-- A RESPOSTA SAI NA HORA, E NAO NO PROXIMO MINUTO.
--
-- 23/09/2026, primeiro teste do Eddy num salao zerado. A conta do relogio:
--
--   12:57:00  a mensagem da dona chega
--   12:57:10  o Eddy decide a resposta          (+10s pensando)
--   12:57:24  a resposta sai                    (+14s PARADA NA FILA)
--
-- Vinte e cinco segundos. Os dez primeiros sao o modelo pensando e tem que
-- existir. Os catorze ultimos sao a mensagem escrita, pronta, esperando o
-- agendador do worker ENVIO acordar -- ele bate a cada 60 segundos, entao a
-- espera pode chegar a quase um minuto.
--
-- POR QUE ISSO E PIOR QUE PARECE. Quem esta do outro lado ve "entregue" e
-- silencio. Ela conclui que quebrou e manda de novo -- que foi exatamente o
-- que a dona fez no teste. Num WhatsApp, meio minuto sem resposta nao e
-- lentidao, e ausencia.
--
-- O CONSERTO NAO E NO EDDY. Ele seria o mais facil (a Edge Function ja tem o
-- que precisa para chamar a `whatsapp-sender` direto), e seria errado: a
-- atendente das clientes sofre a mesma espera, e a resposta escrita a mao pela
-- equipe tambem. O lugar certo e a porta por onde TODA mensagem sai.
--
-- E O DISPARO NAO E NOVO. `app.tick_worker` ja sabe chamar o worker com os
-- segredos do vault E ja tem a trava contra tiro duplicado
-- (PULADO_ANTERIOR_EM_VOO). Escrever um segundo caminho de disparo seria criar
-- duas verdades que vao divergir. Aqui a gente chama o mesmo.
--
-- TRES COISAS QUE ISSO GARANTE, DE GRACA:
--
--  1. Duas mensagens seguidas nao viram dois disparos. `tick_worker` grava em
--     `worker_runs` dentro da MESMA transacao, entao a segunda chamada enxerga
--     a primeira e se cala. O Eddy respondeu duas linhas no teste: vai sair um
--     disparo so.
--  2. Se a transacao que enfileirou for revertida, o disparo vai junto:
--     `net.http_post` grava numa tabela e participa da transacao. Nao existe
--     disparo para mensagem que nao chegou a existir.
--  3. Se o envio falhar, quem enfileirou NAO falha junto. O bloco abaixo
--     engole o erro de proposito: perder o disparo custa os mesmos 60 segundos
--     de antes -- perder a mensagem custa a conversa.
--
-- EFEITO COLATERAL ACEITO: `app.worker_heartbeat` do ENVIO passa a bater fora
-- do compasso do cron, porque agora ele e acordado por mensagem tambem. Quem
-- ler aquela tabela para saber "o agendador esta vivo?" precisa saber disso.

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

  -- O interruptor vale para conversa de CLIENTE. Conversa do dono configurando
  -- o proprio salao nunca foi assunto dele. (Consertado em 18/09/2026.)
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

  -- A MENSAGEM ESTA NA FILA. ACORDA QUEM ENTREGA, AGORA.
  --
  -- O erro e engolido de proposito: se o disparo falhar, o cron pega no proximo
  -- minuto e a unica perda sao os segundos que a gente ja perdia antes. Deixar
  -- o erro subir derrubaria a gravacao da mensagem junto -- trocaria uma espera
  -- por uma conversa perdida.
  begin
    perform app.tick_worker('ENVIO', 'whatsapp-sender', '{}'::jsonb, 60000);
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'ok', true, 'duplicate', false,
    'outboxId', v_outbox_id, 'messageId', v_message_id, 'recipient', v_endereco
  );
end;
$function$;

comment on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid, text, text, text) is
  'Porta unica de saida de mensagem. Desde 23/09/2026 acorda o worker ENVIO na hora, em vez de deixar a resposta esperar ate um minuto pelo cron. O disparo reusa app.tick_worker, entao herda a trava contra tiro duplicado, e falha em silencio de proposito.';
