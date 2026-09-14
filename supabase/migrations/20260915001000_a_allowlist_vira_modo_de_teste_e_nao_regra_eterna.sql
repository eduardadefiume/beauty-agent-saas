-- A ALLOWLIST VIRA MODO DE TESTE, E DEIXA DE SER REGRA ETERNA.
--
-- Ate aqui, TODA mensagem recebida passava por uma lista de numeros
-- autorizados: quem nao estivesse nela tinha a mensagem guardada mas nao
-- recebia resposta nenhuma. Isso nasceu certo -- durante o piloto, um
-- desconhecido nao podia receber resposta de uma IA em teste.
--
-- Num salao de verdade e absurdo. Cliente nova escreve todo dia, e e
-- exatamente ela que o agente existe para atender. A lista, que era protecao,
-- viraria silencio para quem esta querendo marcar.
--
-- Entao a lista continua existindo, e continua valendo -- mas por escolha do
-- canal, nao por natureza do sistema:
--
--   allowlist_required = true   -> MODO TESTE. So responde quem esta na lista.
--                                  E o default, porque um canal recem-conectado
--                                  responder o mundo inteiro sem ninguem mandar
--                                  e o erro mais caro possivel.
--   allowlist_required = false  -> SALAO DE VERDADE. Responde qualquer cliente
--                                  que escrever.
--
-- O que NAO muda: retencao. Toda mensagem continua sendo guardada dos dois
-- jeitos -- essa separacao entre "quem eu respondo" e "o que eu guardo" e de
-- 20/08 e continua de pe.
--
-- As travas que substituem a lista no dia a dia ja existem: a parada de
-- emergencia por salao, e a pausa por conversa, que deixa o dono assumir uma
-- cliente sem calar as outras trinta.
--
-- O canal do piloto sai destravado no fim deste arquivo: e o unico que existe,
-- e ele precisa atender numero de gente de fora agora.

alter table app.channel_connections
  add column if not exists allowlist_required boolean not null default true;

comment on column app.channel_connections.allowlist_required is
  'true: so responde quem esta na channel_allowlist (modo teste). false: responde qualquer cliente que escrever, que e como um salao de verdade funciona. Nao afeta retencao: toda mensagem continua sendo guardada.';

create or replace function api.ingest_whatsapp_webhook(
  p_waba_id text, p_phone_number_id text, p_payload_sha256 text,
  p_correlation_id text, p_events jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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

    -- A UNICA MUDANCA: a lista deixa de ser obrigatoria por natureza.
    --
    -- Ela nasceu como trava de piloto, para um desconhecido nao receber
    -- resposta de IA enquanto a gente testava. Num salao de verdade ela e
    -- absurda: cliente nova escreve todo dia, e e exatamente ela que o agente
    -- existe para atender. Agora e o canal que diz se esta em modo teste.
    is_allowlisted := (not contact_required and event_contact = '')
      or not coalesce(target_connection.allowlist_required, true)
      or (
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

    insert into app.inbox_events (
      tenant_id, connection_id, provider, external_event_id, event_type,
      payload, payload_sha256, contact_authorized, status, rejection_reason,
      correlation_id, processed_at
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
      tenant_id, actor_type, action, entity_type, correlation_id, result, metadata_minimized
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
$function$;

-- O canal do piloto sai destravado: e o unico que existe e precisa atender
-- numero de gente de fora agora.
update app.channel_connections
   set allowlist_required = false, updated_at = statement_timestamp()
 where external_sender_id = '1263097080223211';

-- Recriar a funcao mantem as concessoes antigas no banco em producao, mas num
-- banco reconstruido do zero ela nasceria aberta. A guardrail pegou isso aqui
-- antes de virar porta anonima -- de novo.
revoke all on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function api.ingest_whatsapp_webhook(text, text, text, text, jsonb)
  to service_role;
