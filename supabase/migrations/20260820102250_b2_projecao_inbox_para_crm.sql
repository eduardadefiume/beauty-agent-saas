-- B2: projeta eventos de inbox do WhatsApp no modelo de CRM.
--
-- Contexto: o B1 provou que a mensagem real da Meta chega em app.inbox_events,
-- mas o evento ficava em PENDING para sempre porque nada o lia. Esta migracao
-- cria o worker que transforma o evento bruto em contato, canal, conversa e
-- mensagem -- o que a tela de atendimento e o agente precisam consultar.
--
-- ESCOLHA DE MODELO. O banco tem dois modelos paralelos para a mesma coisa:
-- app.contacts/conversations/messages (05/08) e app.crm_* (13/08). Ambos estao
-- com ZERO linhas, entao nao ha migracao de dados a fazer e a escolha e livre.
-- A projecao vai para app.crm_*, por tres motivos verificados no schema:
--   1. crm_* usa FK composta (tenant_id, id) em todas as relacoes; o modelo
--      antigo so ganhou isso depois, em migracao de correcao;
--   2. crm_contact_channels separa o telefone do contato, que e a condicao para
--      resolver a duplicacao de telefone apontada na politica de retencao;
--   3. app.conversations tem unique(tenant_id, contact_id) -- um contato nunca
--      poderia ter uma segunda conversa. E o item E9 do plano, e e um modelo
--      errado para atendimento recorrente.
-- O modelo antigo fica orfao e deve ser removido em migracao propria, depois de
-- auditar quem ainda o referencia. Nao e removido aqui de proposito: uma coisa
-- por migracao.
--
-- UMA CONVERSA POR CONTATO POR CANAL. external_conversation_ref recebe o
-- endereco normalizado, entao o indice unico parcial ja existente
-- (tenant_id, channel_connection_id, external_conversation_ref) garante uma
-- unica thread por numero por canal -- que e exatamente como o WhatsApp
-- funciona. Isso NAO repete o erro do E9: o escopo aqui inclui o canal, e o
-- mesmo contato pode ter conversa em outro canal. Se depois for preciso o
-- conceito de "atendimento" que abre e fecha, ele e uma entidade separada, e
-- nao deve ser confundido com a thread.
--
-- IDEMPOTENCIA. crm_messages tem indice unico parcial em
-- (tenant_id, provider_message_id); o insert usa on conflict do nothing. Rodar
-- o worker duas vezes sobre o mesmo evento nao duplica mensagem.
--
-- SEM ESTADO PROCESSING. Todo o processamento de um lote acontece numa unica
-- transacao. Se o processo morrer no meio, tudo volta atras e os eventos
-- continuam PENDING -- que e o estado correto para serem tentados de novo.
-- Marcar PROCESSING so faria sentido se houvesse commit intermediario, e ai
-- criaria linhas presas nesse estado se o worker caisse.

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
    -- Contato sem autorizacao nao vira registro de CRM. O webhook ja avaliou a
    -- allowlist; aqui so respeitamos a decisao dele.
    if not coalesce(v_evento.contact_authorized, false) then
      update app.inbox_events
         set status = 'REJECTED',
             rejection_reason = coalesce(rejection_reason, 'CONTACT_NOT_AUTHORIZED'),
             processed_at = statement_timestamp()
       where id = v_evento.id;
      v_rejeitados := v_rejeitados + 1;
      continue;
    end if;

    -- Só mensagens recebidas viram conversa. STATUS (recibo de entrega de
    -- mensagem nossa), ERROR e CHANGE sao consumidos sem projecao: nao ha
    -- mensagem de cliente neles. Recibos passarao a atualizar a mensagem de
    -- saida quando existir envio (trilha de outbox).
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

      -- Texto do corpo, ou legenda quando for midia. Truncado no limite da
      -- coluna para nao derrubar o lote inteiro por uma mensagem gigante.
      v_corpo := left(
        coalesce(
          v_evento.payload #>> '{message,text,body}',
          v_evento.payload #>> '{message,image,caption}',
          v_evento.payload #>> '{message,video,caption}',
          v_evento.payload #>> '{message,document,caption}'
        ),
        4096
      );

      -- Unidade so e atribuida quando o tenant tem exatamente uma. Com varias,
      -- adivinhar seria pior que deixar nulo para o operador resolver.
      select case when count(*) = 1 then min(u.id) else null end
        into v_unidade_id
        from app.units u
       where u.tenant_id = v_evento.tenant_id;

      -- Contato: procura pelo canal ja cadastrado; se nao houver, cria os dois.
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

      -- Conversa: uma por contato por canal, reaberta se estava fechada.
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
        -- O bloco tem savepoint proprio: o erro desfaz so a projecao deste
        -- evento, o lote continua. FAILED e terminal -- o worker so pega
        -- PENDING -- entao um evento problematico nao entra em laco infinito.
        update app.inbox_events
           set status = 'FAILED',
               rejection_reason = left('PROJECTION_ERROR: ' || sqlerrm, 500),
               processed_at = statement_timestamp()
         where id = v_evento.id;
        v_falhados := v_falhados + 1;
    end;
  end loop;

  return query select v_processados, v_rejeitados, v_falhados, v_ignorados;
end;
$function$;

-- CREATE FUNCTION concede EXECUTE a PUBLIC por padrao, e anon/authenticated
-- herdam desse grant. Foi exatamente o que deixou dez RPCs abertas ao papel
-- anonimo ate o F0-01b. Esta funcao escreve em quatro tabelas com
-- SECURITY DEFINER, entao o fecho vem junto com a criacao, nao depois.
revoke execute on function app.project_inbox_events(integer) from public;
revoke all on function app.project_inbox_events(integer) from anon, authenticated;
grant execute on function app.project_inbox_events(integer) to service_role;

comment on function app.project_inbox_events(integer) is
  'B2: projeta app.inbox_events PENDING em crm_contacts/channels/conversations/messages. Idempotente por provider_message_id. Chamada por pg_cron.';
