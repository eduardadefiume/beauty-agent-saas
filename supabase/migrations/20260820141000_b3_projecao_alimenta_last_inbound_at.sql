-- B3 (parte 2): a projecao passa a alimentar last_inbound_at.
--
-- Separada em migracao propria porque toca uma funcao ja existente, enquanto a
-- parte 1 so cria coisas novas. Sem esta parte, conversas novas nasceriam com
-- last_inbound_at nulo e todo envio seria recusado com SERVICE_WINDOW_CLOSED --
-- a fila funcionaria e nada sairia.

-- A projecao passa a alimentar last_inbound_at. Sem isso a janela nunca abriria
-- para conversas novas e todo envio seria recusado com SERVICE_WINDOW_CLOSED.
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
        message_type, body_text, occurred_at, metadata_minimized
      ) values (
        v_evento.tenant_id, v_conversa_id, 'INBOUND', v_evento.external_event_id,
        v_tipo, v_corpo, v_ocorrido_em,
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

revoke execute on function app.project_inbox_events(integer) from public;
revoke all on function app.project_inbox_events(integer) from anon, authenticated;
grant execute on function app.project_inbox_events(integer) to service_role;
