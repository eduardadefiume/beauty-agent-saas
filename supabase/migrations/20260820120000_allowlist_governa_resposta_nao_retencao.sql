-- A allowlist passa a governar QUEM O AGENTE RESPONDE, nao QUAL MENSAGEM E GUARDADA.
--
-- O PROBLEMA. api.ingest_whatsapp_webhook descartava o conteudo da mensagem
-- quando o remetente nao estava na allowlist:
--
--     safe_payload := case
--       when is_authorized then coalesce(event_record -> 'payload', '{}'::jsonb)
--       else jsonb_build_object(..., 'reason', 'CONTACT_NOT_ALLOWLISTED')
--     end;
--
-- O texto era substituido por um carimbo e o evento nascia REJECTED. Nao ha
-- como recuperar depois: o dado nunca entrou.
--
-- POR QUE ISSO QUEBRA O PILOTO. O desenho combinado com a proprietaria e:
-- nas primeiras semanas, o agente responde automaticamente apenas um punhado
-- de clientes; todas as demais continuam sendo atendidas pelo William, na mao,
-- dentro do app. Com o comportamento antigo, as mensagens dessas "demais"
-- seriam destruidas na chegada e o William nunca as veria. Ele perderia
-- agendamento real de cliente real.
--
-- Um numero migrado para a Cloud API deixa de funcionar no WhatsApp Business.
-- Ou seja: se o nosso app nao guarda a mensagem, ela nao existe em lugar
-- nenhum. Descartar conteudo aqui nao e cautela, e perda de dado do cliente.
--
-- A CORRECAO. Duas responsabilidades que estavam coladas passam a ser
-- separadas:
--   - RETENCAO: toda mensagem de um canal conhecido e guardada integralmente.
--     E conversa do negocio dele, e ele precisa ver e responder.
--   - AUTOMACAO: contact_authorized continua dizendo, com honestidade, se o
--     contato esta na allowlist ativa. Quem consome esse campo e o agente, na
--     hora de decidir se pode responder sozinho -- nao o ingestor, na hora de
--     decidir se grava.
--
-- O nome da coluna e mantido e o significado dela nao muda: "este contato esta
-- na allowlist". O que muda e quem age sobre ela.
--
-- LGPD. Guardar o conteudo nao amplia a base legal: sao conversas do proprio
-- estabelecimento com as clientes dele, das quais ele ja e controlador e que ja
-- estavam no WhatsApp Business. A politica de retencao vigente (conteudo de
-- mensagem por 12 meses, revogacao de consentimento com precedencia sobre
-- qualquer prazo) continua valendo integralmente.

create or replace function api.ingest_whatsapp_webhook(
  p_waba_id text,
  p_phone_number_id text,
  p_payload_sha256 text,
  p_correlation_id text,
  p_events jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_connection app.channel_connections%rowtype;
  event_record jsonb;
  event_contact text;
  contact_required boolean;
  is_allowlisted boolean;
  inserted_rows integer;
  accepted_count integer := 0;
  allowlisted_count integer := 0;
  duplicate_count integer := 0;
  incoming_external_event_id text;
  incoming_event_type text;
begin
  if p_waba_id is null or length(trim(p_waba_id)) = 0
    or p_phone_number_id is null or length(trim(p_phone_number_id)) = 0
    or p_payload_sha256 is null
    or p_payload_sha256 !~ '^[a-f0-9]{64}$'
    or p_correlation_id is null or length(p_correlation_id) not between 8 and 128
    or p_events is null
    or jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_WHATSAPP_WEBHOOK_INPUT';
  end if;

  select connection.*
    into target_connection
  from app.channel_connections connection
  where connection.channel = 'WHATSAPP'
    and connection.external_account_id = trim(p_waba_id)
    and connection.external_sender_id = trim(p_phone_number_id)
    and connection.status in ('SANDBOX_CONNECTED', 'CONTROLLED_PRODUCTION', 'PRODUCTION')
  limit 1;

  -- Canal desconhecido continua sendo recusa total: sem conexao nao ha tenant
  -- a quem pertencer o dado, e guardar seria criar orfao sem dono.
  if not found then
    return jsonb_build_object(
      'knownConnection', false,
      'accepted', 0,
      'allowlisted', 0,
      'duplicates', 0
    );
  end if;

  for event_record in select value from jsonb_array_elements(p_events)
  loop
    incoming_external_event_id := event_record ->> 'externalEventId';
    incoming_event_type := event_record ->> 'eventType';
    event_contact := regexp_replace(coalesce(event_record ->> 'contact', ''), '[^0-9]', '', 'g');

    if incoming_external_event_id is null
      or length(trim(incoming_external_event_id)) not between 1 and 240
      or incoming_event_type is null
      or length(trim(incoming_event_type)) not between 1 and 160
      or jsonb_typeof(coalesce(event_record -> 'payload', '{}'::jsonb)) <> 'object' then
      raise exception using errcode = '22023', message = 'INVALID_WHATSAPP_EVENT';
    end if;

    contact_required := incoming_event_type like 'WHATSAPP_MESSAGE_%'
      or incoming_event_type like 'WHATSAPP_STATUS_%';

    is_allowlisted := (not contact_required and event_contact = '') or (
      event_contact <> '' and exists (
        select 1
        from app.channel_allowlist allowlist
        where allowlist.tenant_id = target_connection.tenant_id
          and allowlist.connection_id = target_connection.id
          and allowlist.normalized_contact = event_contact
          and allowlist.status = 'ACTIVE'
          and (allowlist.expires_at is null or allowlist.expires_at > statement_timestamp())
      )
    );

    -- Payload integral, sempre. A allowlist nao decide mais o que e guardado.
    insert into app.inbox_events (
      tenant_id,
      connection_id,
      provider,
      external_event_id,
      event_type,
      payload,
      payload_sha256,
      contact_authorized,
      status,
      rejection_reason,
      correlation_id,
      processed_at
    ) values (
      target_connection.tenant_id,
      target_connection.id,
      'WHATSAPP',
      incoming_external_event_id,
      incoming_event_type,
      coalesce(event_record -> 'payload', '{}'::jsonb),
      p_payload_sha256,
      is_allowlisted,
      'PENDING'::app.inbox_event_status,
      null,
      p_correlation_id,
      null
    )
    on conflict (tenant_id, connection_id, provider, external_event_id) do nothing;

    get diagnostics inserted_rows = row_count;
    if inserted_rows = 0 then
      duplicate_count := duplicate_count + 1;
    else
      accepted_count := accepted_count + 1;
      if is_allowlisted then
        allowlisted_count := allowlisted_count + 1;
      end if;
    end if;
  end loop;

  if accepted_count + duplicate_count > 0 then
    update app.channel_connections
    set last_webhook_at = statement_timestamp()
    where id = target_connection.id;

    insert into app.audit_logs (
      tenant_id,
      actor_type,
      action,
      entity_type,
      correlation_id,
      result,
      metadata_minimized
    ) values (
      target_connection.tenant_id,
      'SYSTEM',
      'WHATSAPP_WEBHOOK_INGESTED',
      'INBOX_EVENT',
      p_correlation_id,
      'SUCCESS'::app.audit_result,
      jsonb_build_object(
        'acceptedCount', accepted_count,
        'allowlistedCount', allowlisted_count,
        'duplicateCount', duplicate_count
      )
    );
  end if;

  return jsonb_build_object(
    'knownConnection', true,
    'accepted', accepted_count,
    'allowlisted', allowlisted_count,
    'duplicates', duplicate_count
  );
end;
$$;

revoke all on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  to service_role;

-- B2 acompanha: projeta toda mensagem, esteja o contato na allowlist ou nao.
-- contact_authorized viaja junto para os metadados da mensagem, para que o
-- agente saiba depois se aquela conversa e de resposta automatica ou de
-- atendimento humano -- e para que a tela possa sinalizar isso ao operador.
create or replace function app.project_inbox_events(p_limit integer default 100)
returns table (
  processados integer,
  rejeitados integer,
  falhados integer,
  ignorados integer
)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_evento record;
  v_endereco text;
  v_contato_id uuid;
  v_conversa_id uuid;
  v_unidade_id uuid;
  v_tipo text;
  v_corpo text;
  v_ocorrido_em timestamptz;
  v_timestamp text;
  v_processados integer := 0;
  v_rejeitados integer := 0;
  v_falhados integer := 0;
  v_ignorados integer := 0;
begin
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'p_limit deve estar entre 1 e 1000, recebido %', p_limit;
  end if;

  for v_evento in
    select e.*
      from app.inbox_events e
     where e.status = 'PENDING'
     order by e.received_at
     limit p_limit
       for update skip locked
  loop
    if v_evento.event_type not like 'WHATSAPP\_MESSAGE\_%' then
      update app.inbox_events
         set status = 'PROCESSED',
             processed_at = statement_timestamp()
       where id = v_evento.id;
      v_ignorados := v_ignorados + 1;
      continue;
    end if;

    begin
      v_endereco := regexp_replace(
        coalesce(v_evento.payload #>> '{message,from}', ''), '[^0-9]', '', 'g'
      );
      if length(v_endereco) < 4 then
        raise exception 'remetente ausente ou invalido no payload';
      end if;

      v_timestamp := v_evento.payload #>> '{message,timestamp}';
      v_ocorrido_em := case
        when v_timestamp ~ '^[0-9]+$' then to_timestamp(v_timestamp::bigint)
        else v_evento.received_at
      end;

      v_tipo := case
        when v_evento.event_type = 'WHATSAPP_MESSAGE_TEXT' then 'TEXT'
        when v_evento.event_type in (
          'WHATSAPP_MESSAGE_IMAGE', 'WHATSAPP_MESSAGE_AUDIO', 'WHATSAPP_MESSAGE_VIDEO',
          'WHATSAPP_MESSAGE_DOCUMENT', 'WHATSAPP_MESSAGE_STICKER', 'WHATSAPP_MESSAGE_VOICE'
        ) then 'MEDIA'
        else 'SYSTEM'
      end;

      v_corpo := left(
        coalesce(
          v_evento.payload #>> '{message,text,body}',
          v_evento.payload #>> '{message,image,caption}',
          v_evento.payload #>> '{message,video,caption}',
          v_evento.payload #>> '{message,document,caption}'
        ),
        4096
      );

      select case when count(*) = 1 then (array_agg(u.id))[1] else null end
        into v_unidade_id
        from app.units u
       where u.tenant_id = v_evento.tenant_id;

      select c.contact_id into v_contato_id
        from app.crm_contact_channels c
       where c.tenant_id = v_evento.tenant_id
         and c.provider = 'WHATSAPP'
         and c.address_normalized = v_endereco;

      if v_contato_id is null then
        insert into app.crm_contacts (tenant_id, unit_id, display_name, status)
        values (v_evento.tenant_id, v_unidade_id, null, 'ACTIVE')
        returning id into v_contato_id;

        insert into app.crm_contact_channels (
          tenant_id, contact_id, channel_connection_id, provider, address_normalized, is_primary
        )
        values (
          v_evento.tenant_id, v_contato_id, v_evento.connection_id, 'WHATSAPP', v_endereco, true
        );
      end if;

      insert into app.crm_conversations (
        tenant_id, unit_id, contact_id, channel_connection_id,
        external_conversation_ref, status, last_message_at
      )
      values (
        v_evento.tenant_id, v_unidade_id, v_contato_id, v_evento.connection_id,
        v_endereco, 'OPEN', v_ocorrido_em
      )
      on conflict (tenant_id, channel_connection_id, external_conversation_ref)
        where external_conversation_ref is not null
      do update set
        status = 'OPEN',
        last_message_at = greatest(
          crm_conversations.last_message_at, excluded.last_message_at
        ),
        updated_at = statement_timestamp()
      returning id into v_conversa_id;

      insert into app.crm_messages (
        tenant_id, conversation_id, direction, provider_message_id,
        message_type, body_text, occurred_at, metadata_minimized
      )
      values (
        v_evento.tenant_id, v_conversa_id, 'INBOUND', v_evento.external_event_id,
        v_tipo, v_corpo, v_ocorrido_em,
        jsonb_build_object(
          'eventType', v_evento.event_type,
          'inboxEventId', v_evento.id,
          'agentMayReply', coalesce(v_evento.contact_authorized, false)
        )
      )
      on conflict (tenant_id, provider_message_id)
        where provider_message_id is not null
      do nothing;

      update app.inbox_events
         set status = 'PROCESSED',
             processed_at = statement_timestamp()
       where id = v_evento.id;
      v_processados := v_processados + 1;

    exception
      when others then
        update app.inbox_events
           set status = 'FAILED',
               failure_reason = left('PROJECTION_ERROR: ' || sqlerrm, 500),
               processed_at = statement_timestamp()
         where id = v_evento.id;
        v_falhados := v_falhados + 1;
    end;
  end loop;

  return query select v_processados, v_rejeitados, v_falhados, v_ignorados;
end;
$function$;

revoke execute on function app.project_inbox_events(integer) from public;
revoke all on function app.project_inbox_events(integer) from anon, authenticated;
grant execute on function app.project_inbox_events(integer) to service_role;
