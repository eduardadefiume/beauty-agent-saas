-- B3: fila de envio (outbox) para o WhatsApp.
--
-- Ate aqui o sistema so escutava. O B1 provou que a mensagem chega, o B2 a
-- transformou em conversa -- e ela ficava la, sem resposta possivel. Esta
-- migracao cria a metade que faltava.
--
-- POR QUE UMA FILA, E NAO UM POST DIRETO. Chamar a Graph API de dentro do
-- pedido do usuario acopla a resposta do app a disponibilidade da Meta: se a
-- API estiver lenta, a tela trava; se falhar, a mensagem se perde sem registro.
-- Com fila, escrever a mensagem e entregar a mensagem sao dois atos separados,
-- e o segundo pode falhar e ser tentado de novo sem que o primeiro seja
-- desfeito.
--
-- DUAS TABELAS, DOIS PAPEIS. crm_messages e o registro da CONVERSA -- o que foi
-- dito, quando, por quem. outbox_messages e o registro da ENTREGA -- tentativas,
-- erro, quando tentar de novo. Misturar os dois faria a tabela de conversa
-- carregar mecanica de fila, e a tela teria que filtrar lixo operacional para
-- desenhar um balao de mensagem.
--
-- A mensagem entra em crm_messages IMEDIATAMENTE, antes de ser entregue, com
-- provider_message_id nulo. E de proposito: e assim que o WhatsApp se comporta
-- (a mensagem aparece com o reloginho antes do tique). O operador ve o que
-- escreveu na hora; o estado de entrega vem depois.
--
-- A JANELA DE 24 HORAS. A Meta so aceita texto livre dentro de 24h contadas da
-- ULTIMA mensagem da cliente. Fora disso, apenas template aprovado. Para saber
-- isso e preciso guardar quando foi a ultima mensagem DELA -- e last_message_at
-- nao serve, porque passa a ser tocada tambem pelas mensagens que nos enviamos.
-- Dai a coluna last_inbound_at.
--
-- A validacao vive aqui, no enfileiramento, e nao na tela. Bloquear no banco
-- garante que nenhum caminho (tela, agente, integracao futura) consiga gastar
-- uma chamada que a Meta vai recusar.

alter table app.crm_conversations
  add column if not exists last_inbound_at timestamptz;

comment on column app.crm_conversations.last_inbound_at is
  'Horario da ultima mensagem RECEBIDA da cliente. Base da janela de 24h para texto livre. Distinto de last_message_at, que tambem e tocado por mensagens enviadas por nos.';

-- Retroalimenta com o que ja existe, para conversas projetadas antes desta coluna.
update app.crm_conversations c
   set last_inbound_at = sub.ultimo
  from (
    select m.tenant_id, m.conversation_id, max(m.occurred_at) as ultimo
      from app.crm_messages m
     where m.direction = 'INBOUND'
     group by m.tenant_id, m.conversation_id
  ) sub
 where sub.tenant_id = c.tenant_id
   and sub.conversation_id = c.id
   and c.last_inbound_at is distinct from sub.ultimo;

do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'outbox_status') then
    create type app.outbox_status as enum ('PENDING', 'SENDING', 'SENT', 'FAILED', 'CANCELLED');
  end if;
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'outbound_actor') then
    create type app.outbound_actor as enum ('AGENT', 'HUMAN', 'SYSTEM');
  end if;
end $$;

create table if not exists app.outbox_messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id) on delete restrict,
  conversation_id uuid not null,
  message_id uuid not null,
  channel_connection_id uuid references app.channel_connections(id) on delete set null,
  recipient_address text not null check (length(trim(recipient_address)) between 4 and 80),
  kind text not null check (kind in ('TEXT', 'TEMPLATE')),
  body_text text check (body_text is null or length(body_text) <= 4096),
  template_name text,
  template_language text,
  template_params jsonb,
  actor app.outbound_actor not null,
  actor_user_id uuid references app.profiles(id) on delete set null,
  status app.outbox_status not null default 'PENDING',
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default statement_timestamp(),
  provider_message_id text,
  last_error text,
  idempotency_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  sent_at timestamptz,
  constraint outbox_conversation_fk foreign key (tenant_id, conversation_id)
    references app.crm_conversations(tenant_id, id) on delete cascade,
  constraint outbox_message_fk foreign key (tenant_id, message_id)
    references app.crm_messages(tenant_id, id) on delete cascade,
  constraint outbox_tenant_id_id_unique unique (tenant_id, id),
  -- Texto livre exige corpo; template exige nome. Impede enfileirar mensagem
  -- vazia que so falharia depois, ja tendo consumido uma chamada.
  constraint outbox_kind_payload_check check (
    (kind = 'TEXT' and body_text is not null and length(trim(body_text)) > 0)
    or (kind = 'TEMPLATE' and template_name is not null)
  ),
  constraint outbox_sent_requires_provider_id check (
    (status = 'SENT') = (provider_message_id is not null)
  )
);

-- Idempotencia de enfileiramento: dois cliques no botao enviar, ou duas
-- execucoes do agente sobre o mesmo gatilho, produzem uma mensagem so.
create unique index if not exists outbox_idempotency_unique_idx
  on app.outbox_messages (tenant_id, idempotency_key);

-- Indice do consumidor: so as linhas que ainda podem ser entregues.
create index if not exists outbox_pendentes_idx
  on app.outbox_messages (next_attempt_at)
  where status in ('PENDING', 'SENDING');

create index if not exists outbox_conversa_idx
  on app.outbox_messages (tenant_id, conversation_id, created_at desc);

alter table app.outbox_messages enable row level security;

-- Sem policy permissiva: o acesso e exclusivamente por RPC SECURITY DEFINER.
-- RLS habilitada sem policy nega tudo por padrao aos papeis nao privilegiados,
-- que e o estado desejado enquanto nao houver leitura direta pela tela.

create or replace function app.enqueue_outbound_message(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_body_text text,
  p_actor app.outbound_actor,
  p_idempotency_key text,
  p_actor_user_id uuid default null
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
begin
  if p_body_text is null or length(trim(p_body_text)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_BODY');
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 8 and 128 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_IDEMPOTENCY_KEY');
  end if;

  -- Reentrada: mesma chave devolve o que ja foi enfileirado, sem duplicar.
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

  -- A regra da Meta, aplicada antes de gastar a chamada.
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

  insert into app.crm_messages (
    tenant_id, conversation_id, direction, provider_message_id,
    message_type, body_text, occurred_at, metadata_minimized
  )
  values (
    p_tenant_id, p_conversation_id, 'OUTBOUND', null,
    'TEXT', left(p_body_text, 4096), statement_timestamp(),
    jsonb_build_object('actor', p_actor, 'deliveryStatus', 'PENDING')
  )
  returning id into v_message_id;

  insert into app.outbox_messages (
    tenant_id, conversation_id, message_id, channel_connection_id,
    recipient_address, kind, body_text, actor, actor_user_id, idempotency_key
  )
  values (
    p_tenant_id, p_conversation_id, v_message_id, v_conversa.channel_connection_id,
    v_endereco, 'TEXT', left(p_body_text, 4096), p_actor, p_actor_user_id,
    trim(p_idempotency_key)
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

-- Reserva um lote para entrega. FOR UPDATE SKIP LOCKED permite mais de um
-- worker sem que dois peguem a mesma mensagem.
create or replace function app.claim_outbox_batch(p_limit integer default 20)
returns table (
  id uuid,
  tenant_id uuid,
  recipient_address text,
  kind text,
  body_text text,
  attempts integer
)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'p_limit deve estar entre 1 e 200, recebido %', p_limit;
  end if;

  return query
  with reservados as (
    select o.id
      from app.outbox_messages o
     where o.status = 'PENDING'
       and o.next_attempt_at <= statement_timestamp()
     order by o.next_attempt_at
     limit p_limit
       for update skip locked
  )
  update app.outbox_messages o
     set status = 'SENDING',
         attempts = o.attempts + 1,
         updated_at = statement_timestamp()
    from reservados r
   where o.id = r.id
  returning o.id, o.tenant_id, o.recipient_address, o.kind, o.body_text, o.attempts;
end;
$function$;

-- Registra o desfecho de uma tentativa. Recuo exponencial ate 5 tentativas.
create or replace function app.mark_outbox_result(
  p_outbox_id uuid,
  p_success boolean,
  p_provider_message_id text default null,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_linha record;
  v_max_tentativas constant integer := 5;
  v_novo_status app.outbox_status;
begin
  select * into v_linha from app.outbox_messages where id = p_outbox_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'OUTBOX_NOT_FOUND');
  end if;

  if p_success then
    if p_provider_message_id is null or length(trim(p_provider_message_id)) = 0 then
      return jsonb_build_object('ok', false, 'reason', 'MISSING_PROVIDER_MESSAGE_ID');
    end if;

    update app.outbox_messages
       set status = 'SENT',
           provider_message_id = trim(p_provider_message_id),
           last_error = null,
           sent_at = statement_timestamp(),
           updated_at = statement_timestamp()
     where id = p_outbox_id;

    update app.crm_messages
       set provider_message_id = trim(p_provider_message_id),
           metadata_minimized = metadata_minimized || jsonb_build_object('deliveryStatus', 'SENT')
     where tenant_id = v_linha.tenant_id and id = v_linha.message_id;

    return jsonb_build_object('ok', true, 'status', 'SENT');
  end if;

  -- Esgotadas as tentativas, para de tentar. FAILED e terminal: o operador ve
  -- o erro na conversa e decide reenviar, em vez de a fila girar para sempre.
  v_novo_status := case
    when v_linha.attempts >= v_max_tentativas then 'FAILED'::app.outbox_status
    else 'PENDING'::app.outbox_status
  end;

  update app.outbox_messages
     set status = v_novo_status,
         last_error = left(coalesce(p_error, 'erro nao informado'), 1000),
         next_attempt_at = statement_timestamp()
           + (interval '30 seconds' * power(2, least(v_linha.attempts, 5))),
         updated_at = statement_timestamp()
   where id = p_outbox_id;

  update app.crm_messages
     set metadata_minimized = metadata_minimized || jsonb_build_object(
           'deliveryStatus', case when v_novo_status = 'FAILED' then 'FAILED' else 'RETRYING' end,
           'lastError', left(coalesce(p_error, ''), 300)
         )
   where tenant_id = v_linha.tenant_id and id = v_linha.message_id;

  return jsonb_build_object('ok', true, 'status', v_novo_status, 'attempts', v_linha.attempts);
end;
$function$;

-- Toda funcao acima e SECURITY DEFINER e escreve. CREATE FUNCTION concede
-- EXECUTE a PUBLIC por padrao, e anon/authenticated herdam. O fecho vem junto
-- com a criacao, nao numa migracao seguinte.
revoke execute on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid) from public;
revoke all on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid) from anon, authenticated;
grant execute on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid) to service_role;

revoke execute on function app.claim_outbox_batch(integer) from public;
revoke all on function app.claim_outbox_batch(integer) from anon, authenticated;
grant execute on function app.claim_outbox_batch(integer) to service_role;

revoke execute on function app.mark_outbox_result(uuid, boolean, text, text) from public;
revoke all on function app.mark_outbox_result(uuid, boolean, text, text) from anon, authenticated;
grant execute on function app.mark_outbox_result(uuid, boolean, text, text) to service_role;
