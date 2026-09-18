-- Responder no status, sem depender da Meta contar qual status foi.
--
-- O QUE EU FUI VERIFICAR. A pergunta era: quando a cliente responde um status e
-- manda só texto ("quero essa promoção"), o WhatsApp entrega para a Cloud API
-- algum ponteiro dizendo QUAL status ela respondeu?
--
-- O QUE EU ACHEI, e a parte incômoda primeiro: eu NÃO consegui provar isso
-- num payload real, e o motivo é físico, não preguiça. O número que temos
-- (+55 16 99412-7035) respondeu `is_on_biz_app: false`, `platform_type:
-- CLOUD_API` -- ou seja, é um número de Cloud API puro, NÃO é Coexistência.
-- Num número assim o app WhatsApp Business não funciona, e sem o app não existe
-- status para ninguém responder. Montar uma Coexistência de verdade exige o app
-- instalado num celular físico lendo um QR code. Não tenho celular.
--
-- O que a Meta documenta, esse eu li: na tabela de comparação de recursos da
-- Coexistência, "Conversas individuais (1:1)" é COMPATÍVEL e "as mensagens
-- enviadas e recebidas são espelhadas entre a API de Nuvem e o app WhatsApp
-- Business". Então a resposta da cliente CHEGA -- ela é uma mensagem 1:1
-- comum. O que a documentação não promete em lugar nenhum é o conteúdo do
-- status citado. O objeto `context` da Cloud API carrega id e remetente da
-- mensagem citada, nunca o conteúdo dela; e o status nunca passou pela Cloud
-- API, então esse id não é resolvível por nenhum endpoint.
--
-- ENTÃO PARE DE DEPENDER DISSO. Esta migração faz o sistema responder certo
-- nos dois mundos -- com ponteiro ou sem.
--
-- 1. GUARDA O PONTEIRO, SE VIER. `reply_context` recebe o objeto `context`
--    cru. No dia em que a Coexistência entrar, a resposta aparece sozinha nos
--    dados, sem eu ter que adivinhar hoje.
--
-- 2. A ARTE VIRA MEMÓRIA DO SALÃO. Quando uma cliente responde o status COM a
--    imagem junto (foi exatamente o que aconteceu aqui), o leitor já entende a
--    arte. Agora essa leitura é guardada em app.status_arts. A chave é o
--    sha256 que a própria Meta manda no payload: a mesma arte respondida por
--    dez clientes tem o mesmo sha256, então dez respostas viram UMA arte
--    conhecida, contada dez vezes.
--
-- 3. QUEM MANDOU SÓ TEXTO PEGA CARONA. A décima primeira cliente que escrever
--    "quero essa promoção" sem imagem nenhuma vai ser atendida com a arte que
--    as outras dez ensinaram. É isso que substitui o ponteiro que a Meta não
--    dá: não é preciso saber qual status ela respondeu se o salão só tem uma
--    arte no ar.
--
-- POR QUE sha256 E NÃO O id DA MÍDIA. O id da mídia muda a cada envio -- a
-- mesma arte reencaminhada por duas clientes tem dois ids. O sha256 é do
-- conteúdo do arquivo: igual sempre que a imagem for a mesma.

-- ---------------------------------------------------------------------------
-- 1. O ponteiro da mensagem citada.
-- ---------------------------------------------------------------------------
alter table app.crm_messages
  add column if not exists reply_context jsonb;

comment on column app.crm_messages.reply_context is
  'Objeto `context` cru da Cloud API quando a mensagem cita outra (inclusive resposta a status). Guarda id e remetente citados; a Meta nao entrega o conteudo citado.';

-- ---------------------------------------------------------------------------
-- 2. As artes que o salão colocou no ar.
-- ---------------------------------------------------------------------------
create table if not exists app.status_arts (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,

  -- Chave de identidade da arte: o hash do arquivo, que a Meta manda no
  -- payload. Mesma imagem = mesmo hash, venha de quem vier.
  content_sha  text not null,

  -- A leitura feita pelo leitor de mídia: o que está escrito e o que aparece.
  understanding text not null,

  -- Quantas clientes trouxeram esta mesma arte. Duas ou mais é sinal forte de
  -- que é o status do momento, e não uma foto qualquer.
  times_seen   integer not null default 1 check (times_seen > 0),

  first_seen_on date not null default (statement_timestamp() at time zone 'America/Sao_Paulo')::date,
  last_seen_at  timestamptz not null default statement_timestamp(),

  -- De onde veio: a cliente respondeu o status, ou o dono mandou a arte.
  source       text not null default 'CLIENTE_RESPONDEU'
    check (source in ('CLIENTE_RESPONDEU', 'DONO_ENVIOU')),

  sample_message_id uuid references app.crm_messages(id) on delete set null,

  -- O dono pode aposentar uma arte que saiu do ar.
  retired_at   timestamptz,

  unique (tenant_id, content_sha)
);

create index if not exists status_arts_vigentes_idx
  on app.status_arts (tenant_id, last_seen_at desc)
  where retired_at is null;

comment on table app.status_arts is
  'Artes de promocao que chegaram ao salao por WhatsApp, deduplicadas pelo sha256 do arquivo. Existem para atender a cliente que responde o status so com texto, quando a Meta nao diz qual status foi.';

-- ---------------------------------------------------------------------------
-- 3. A projeção passa a guardar o ponteiro.
-- ---------------------------------------------------------------------------
create or replace function app.project_inbox_events(p_limit integer default 100)
returns table(processados integer, rejeitados integer, falhados integer, ignorados integer)
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
    select e.* from app.inbox_events e
     where e.status = 'PENDING' order by e.received_at
     limit p_limit for update skip locked
  loop
    if v_evento.event_type not like 'WHATSAPP\_MESSAGE\_%' then
      update app.inbox_events set status = 'PROCESSED', processed_at = statement_timestamp()
       where id = v_evento.id;
      v_ignorados := v_ignorados + 1;
      continue;
    end if;

    begin
      v_endereco := regexp_replace(coalesce(v_evento.payload #>> '{message,from}', ''), '[^0-9]', '', 'g');
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

      v_corpo := left(coalesce(
        v_evento.payload #>> '{message,text,body}',
        v_evento.payload #>> '{message,image,caption}',
        v_evento.payload #>> '{message,video,caption}',
        v_evento.payload #>> '{message,document,caption}'
      ), 4096);

      select case when count(*) = 1 then (array_agg(u.id))[1] else null end
        into v_unidade_id from app.units u where u.tenant_id = v_evento.tenant_id;

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
        ) values (
          v_evento.tenant_id, v_contato_id, v_evento.connection_id, 'WHATSAPP', v_endereco, true
        );
      end if;

      insert into app.crm_conversations (
        tenant_id, unit_id, contact_id, channel_connection_id,
        external_conversation_ref, status, last_message_at, last_inbound_at
      ) values (
        v_evento.tenant_id, v_unidade_id, v_contato_id, v_evento.connection_id,
        v_endereco, 'OPEN', v_ocorrido_em, v_ocorrido_em
      )
      on conflict (tenant_id, channel_connection_id, external_conversation_ref)
        where external_conversation_ref is not null
      do update set
        status = 'OPEN',
        last_message_at = greatest(crm_conversations.last_message_at, excluded.last_message_at),
        last_inbound_at = greatest(crm_conversations.last_inbound_at, excluded.last_inbound_at),
        updated_at = statement_timestamp()
      returning id into v_conversa_id;

      insert into app.crm_messages (
        tenant_id, conversation_id, direction, provider_message_id,
        message_type, body_text, occurred_at, reply_context, metadata_minimized
      ) values (
        v_evento.tenant_id, v_conversa_id, 'INBOUND', v_evento.external_event_id,
        v_tipo, v_corpo, v_ocorrido_em,
        -- O ponteiro da mensagem citada, quando existir. Numa resposta a status
        -- ele aponta para algo que a Cloud API não sabe resolver -- guardamos
        -- assim mesmo, porque é a única evidência de que houve citação.
        v_evento.payload #> '{message,context}',
        jsonb_build_object(
          'eventType', v_evento.event_type,
          'inboxEventId', v_evento.id,
          'agentMayReply', coalesce(v_evento.contact_authorized, false)
        )
      )
      on conflict (tenant_id, provider_message_id) where provider_message_id is not null
      do nothing;

      update app.inbox_events set status = 'PROCESSED', processed_at = statement_timestamp()
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

comment on function app.project_inbox_events(integer) is
  'Transforma evento cru do webhook em conversa e mensagem do CRM. Guarda tambem o `context` da mensagem citada, que e o unico rastro de resposta a status.';

-- ---------------------------------------------------------------------------
-- 4. O leitor de mídia passa a dizer QUE TIPO de imagem era, e arte de
--    promoção vira memória do salão.
--
--    A classificação vem do mesmo passe de visão que já roda -- não custa uma
--    chamada a mais. Sem ela, a foto do cabelo de uma cliente entraria na
--    memória de promoções do salão, que é errado e é vazamento: aquela foto
--    apareceria no contexto das conversas de outras pessoas.
-- ---------------------------------------------------------------------------
drop function if exists public.record_media_understanding(uuid, text, text);

create or replace function public.record_media_understanding(
  p_message_id    uuid,
  p_understanding text,
  p_error         text default null,
  p_kind          text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_msg     record;
  v_sha     text;
  v_arte_id uuid;
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
   where id = p_message_id
  returning tenant_id, direction, media_understanding, metadata_minimized into v_msg;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'MESSAGE_NOT_FOUND');
  end if;

  -- Só arte de promoção, só de mensagem recebida, só com leitura de verdade.
  if p_kind = 'ARTE_DE_PROMOCAO'
     and v_msg.direction = 'INBOUND'
     and coalesce(trim(v_msg.media_understanding), '') <> '' then

    select e.payload #>> '{message,image,sha256}'
      into v_sha
      from app.inbox_events e
     where e.id = (v_msg.metadata_minimized->>'inboxEventId')::uuid;

    if coalesce(v_sha, '') <> '' then
      insert into app.status_arts (
        tenant_id, content_sha, understanding, sample_message_id, source
      ) values (
        v_msg.tenant_id, v_sha, v_msg.media_understanding, p_message_id, 'CLIENTE_RESPONDEU'
      )
      on conflict (tenant_id, content_sha) do update
        set times_seen   = app.status_arts.times_seen + 1,
            last_seen_at = statement_timestamp(),
            -- Uma arte aposentada que volta a aparecer está no ar de novo.
            retired_at   = null
      returning id into v_arte_id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'arteRegistrada', v_arte_id);
end;
$function$;

revoke all on function public.record_media_understanding(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.record_media_understanding(uuid, text, text, text) to service_role;

comment on function public.record_media_understanding(uuid, text, text, text) is
  'Grava a leitura da midia. Quando a leitura for de arte de promocao recebida, registra tambem em app.status_arts, deduplicada pelo sha256 do arquivo.';
