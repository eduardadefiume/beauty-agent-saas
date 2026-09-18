-- Corrige duas falhas do B2, encontradas ao rodar o worker contra o evento real.
--
-- 1. `min(uuid)` nao existe no PostgreSQL. A resolucao de unidade usava min()
--    para pegar o id quando o tenant tem exatamente uma unidade. Trocado por
--    array_agg, que aceita uuid.
--
-- 2. BURACO DE SCHEMA, e o achado que importa. app.inbox_events tem a
--    constraint:
--        check ((status = 'REJECTED') = (rejection_reason is not null))
--    ou seja, rejection_reason so pode existir para REJECTED. Mas o enum
--    inbox_event_status tem FAILED -- e nao havia nenhuma coluna onde gravar a
--    causa da falha. Um evento podia quebrar na projecao e ficar FAILED sem
--    ninguem nunca saber por que.
--
--    A correcao e dar a FAILED a coluna que REJECTED ja tinha, com a mesma
--    regra de simetria: failure_reason existe se e somente se o status e
--    FAILED. Assim as duas saidas de erro sao auditaveis, e nenhuma delas pode
--    ser gravada sem justificativa.

alter table app.inbox_events add column if not exists failure_reason text;

alter table app.inbox_events drop constraint if exists inbox_events_failure_reason_check;
alter table app.inbox_events add constraint inbox_events_failure_reason_check
  check ((status = 'FAILED') = (failure_reason is not null));

comment on column app.inbox_events.failure_reason is
  'Causa da falha de processamento. Preenchida se e somente se status = FAILED, espelhando rejection_reason para REJECTED.';

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
    if not coalesce(v_evento.contact_authorized, false) then
      update app.inbox_events
         set status = 'REJECTED',
             rejection_reason = coalesce(rejection_reason, 'CONTACT_NOT_AUTHORIZED'),
             processed_at = statement_timestamp()
       where id = v_evento.id;
      v_rejeitados := v_rejeitados + 1;
      continue;
    end if;

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

      -- array_agg em vez de min: min() nao tem implementacao para uuid.
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
        jsonb_build_object('eventType', v_evento.event_type, 'inboxEventId', v_evento.id)
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
        -- failure_reason, nao rejection_reason: a constraint da tabela reserva
        -- rejection_reason exclusivamente para REJECTED.
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

-- CREATE OR REPLACE restaura o grant padrao de EXECUTE a PUBLIC. Reaplicar o
-- fecho, como nas demais funcoes corrigidas depois do F0-01b.
revoke execute on function app.project_inbox_events(integer) from public;
revoke all on function app.project_inbox_events(integer) from anon, authenticated;
grant execute on function app.project_inbox_events(integer) to service_role;
