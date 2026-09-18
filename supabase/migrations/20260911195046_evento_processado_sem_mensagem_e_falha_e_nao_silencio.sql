-- EVENTO PROCESSADO SEM MENSAGEM DO OUTRO LADO E FALHA, NAO SILENCIO.
--
-- No dia 31/08, 38 eventos de mensagem (30 textos, 8 fotos) de uma conversa
-- real foram marcados PROCESSED e nenhuma linha apareceu em crm_messages. Sem
-- failure_reason, sem log. O banco dizia que estava tudo certo e um dia inteiro
-- de conversa tinha sumido.
--
-- A funcao de projecao nao mudou entre 28/08 e a descoberta, e ao devolver os
-- 38 para PENDING ela projetou todos sem erro. Ou seja: o codigo de hoje nao
-- reproduz a perda, e a causa daquele dia nao ficou registrada. Nao da para
-- consertar o que nao se sabe - mas da para tornar a FORMA da falha impossivel.
--
-- A forma e esta: "processado" com nada do outro lado. Duas defesas:
--
--   1. project_inbox_events passa a conferir, depois do insert, que a linha
--      existe em crm_messages. Se nao existe, levanta excecao, e o bloco de
--      excecao que ja existia marca FAILED com o motivo. Passa a ser
--      impossivel sair do laco como PROCESSED sem par.
--
--   2. app.inbox_processados_sem_par() lista os que escaparam mesmo assim
--      (eventos antigos, ou um caminho novo que ainda nao existe). E a
--      pergunta "quantas mensagens o banco diz que processou e nao tem?", e a
--      resposta certa e sempre zero. Vira teste no CI.
--
-- E a mesma familia da porta anonima e do RLS: nao e um bug pontual, e um
-- sistema que erra calado. Cada um desses sai com uma trava que faz o erro
-- gritar.

create or replace function app.project_inbox_events(p_limit integer default 100)
returns table(processados integer, rejeitados integer, falhados integer, ignorados integer)
language plpgsql
security definer
set search_path = ''
as $$
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
        v_evento.payload #> '{message,context}',
        jsonb_build_object(
          'eventType', v_evento.event_type,
          'inboxEventId', v_evento.id,
          'agentMayReply', coalesce(v_evento.contact_authorized, false)
        )
      )
      on conflict (tenant_id, provider_message_id) where provider_message_id is not null
      do nothing;

      -- A TRAVA. O "do nothing" acima e legitimo quando a mensagem ja existe
      -- (reenvio da Meta, reprocessamento). Nao e legitimo quando NAO existe:
      -- ai o evento sairia daqui como PROCESSED com nada do outro lado, que e
      -- exatamente a forma da perda de 31/08. Conferir custa um indice; nao
      -- conferir custou um dia de conversa.
      if not exists (
        select 1 from app.crm_messages m
         where m.tenant_id = v_evento.tenant_id
           and m.provider_message_id = v_evento.external_event_id
      ) then
        raise exception 'PROJECAO_SEM_MENSAGEM: evento % processado e nenhuma linha em crm_messages',
          v_evento.external_event_id;
      end if;

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
$$;

-- `create or replace` preserva os grants que ja existiam, entao a porta anonima
-- continua fechada pela varredura de 20260908120000. Mesmo assim o revoke vai
-- aqui: a migracao precisa valer sozinha num banco novo, e o guardrail confere
-- exatamente isso. Quem chama e o cron (como postgres) e o service_role.
revoke all on function app.project_inbox_events(integer) from public, anon, authenticated;
grant execute on function app.project_inbox_events(integer) to service_role;

-- A PERGUNTA QUE PRECISA RESPONDER ZERO.
--
-- Eventos de mensagem que o banco diz que processou e que nao tem par em
-- crm_messages. Depois da trava acima, so eventos antigos podem aparecer aqui;
-- os 38 de 31/08 ja foram recuperados. O teste do CI le esta funcao e falha
-- se vier qualquer linha.
create or replace function app.inbox_processados_sem_par()
returns table(
  inbox_event_id uuid,
  tenant_id uuid,
  event_type text,
  received_at timestamptz,
  external_event_id text
)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.tenant_id, e.event_type, e.received_at, e.external_event_id
    from app.inbox_events e
   where e.status = 'PROCESSED'
     and e.event_type like 'WHATSAPP\_MESSAGE\_%'
     and not exists (
       select 1 from app.crm_messages m
        where m.tenant_id = e.tenant_id
          and m.provider_message_id = e.external_event_id
     )
   order by e.received_at;
$$;

-- Porta fechada por padrao, como o guardrail exige: a funcao e para o CI e
-- para quem tem service_role, nao para o anonimo.
revoke all on function app.inbox_processados_sem_par() from public, anon, authenticated;
grant execute on function app.inbox_processados_sem_par() to service_role;

comment on function app.inbox_processados_sem_par() is
  'Eventos de mensagem marcados PROCESSED sem linha correspondente em crm_messages. A resposta certa e sempre vazio.';
