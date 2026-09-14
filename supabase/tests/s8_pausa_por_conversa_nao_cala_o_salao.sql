-- S8: pausar uma conversa tira ELA da fila, e só ela.
--
-- A parada de emergência que já existia é por salão inteiro. O caso comum do
-- dono é outro: ele vê o agente escorregando com uma cliente e quer assumir
-- AQUELA conversa, sem deixar as outras trinta sem resposta.
--
-- Este teste tranca as três metades disso:
--   1. conversa pausada sai da fila;
--   2. conversa pausada VOLTA quando despausa (pausa que não desfaz é pior que
--      pausa nenhuma — o dono deixaria a cliente no vácuo sem perceber);
--   3. pausar uma conversa NÃO tira as outras do mesmo salão. É a diferença
--      entre esta parada e o botão de emergência, e é o ponto inteiro.
--
-- Roda só contra o projeto DEV, em transação, e desfaz tudo no fim.

begin;

do $$
declare
  v_tenant uuid;
  v_unidade uuid;
  v_conexao uuid;
  v_contato_a uuid;
  v_contato_b uuid;
  v_conv_a uuid;
  v_conv_b uuid;
  v_na_fila integer;
  v_resultado jsonb;
begin
  -- O salão vem da conexão, não o contrário: uma conversa precisa de canal, e
  -- nem todo tenant do banco tem um.
  select cc.tenant_id, cc.id into v_tenant, v_conexao
    from app.channel_connections cc order by cc.created_at limit 1;
  if v_conexao is null then
    raise exception 'S8 precisa de uma conexão de canal para montar as conversas';
  end if;

  select u.id into v_unidade from app.units u where u.tenant_id = v_tenant limit 1;

  -- Duas clientes do MESMO salão, as duas esperando resposta agora.
  insert into app.crm_contacts (tenant_id, unit_id, display_name, status)
  values (v_tenant, v_unidade, 'S8 cliente A', 'ACTIVE') returning id into v_contato_a;
  insert into app.crm_contacts (tenant_id, unit_id, display_name, status)
  values (v_tenant, v_unidade, 'S8 cliente B', 'ACTIVE') returning id into v_contato_b;

  insert into app.crm_contact_channels (tenant_id, contact_id, channel_connection_id, provider, address_normalized, is_primary)
  values (v_tenant, v_contato_a, v_conexao, 'WHATSAPP', '5500000000801', true),
         (v_tenant, v_contato_b, v_conexao, 'WHATSAPP', '5500000000802', true);

  insert into app.crm_conversations (
    tenant_id, unit_id, contact_id, channel_connection_id,
    external_conversation_ref, status, last_message_at, last_inbound_at
  ) values
    (v_tenant, v_unidade, v_contato_a, v_conexao, '5500000000801', 'OPEN',
     statement_timestamp(), statement_timestamp()) returning id into v_conv_a;

  insert into app.crm_conversations (
    tenant_id, unit_id, contact_id, channel_connection_id,
    external_conversation_ref, status, last_message_at, last_inbound_at
  ) values
    (v_tenant, v_unidade, v_contato_b, v_conexao, '5500000000802', 'OPEN',
     statement_timestamp(), statement_timestamp()) returning id into v_conv_b;

  -- A mensagem precisa ter mais de `quiet_seconds` para a fila considerar que
  -- a cliente terminou de escrever.
  insert into app.crm_messages (
    tenant_id, conversation_id, direction, provider_message_id,
    message_type, body_text, occurred_at, metadata_minimized
  ) values
    (v_tenant, v_conv_a, 'INBOUND', 'message:wamid.S8_A', 'TEXT', 'oi, tem horário?',
     statement_timestamp() - interval '60 seconds', jsonb_build_object('agentMayReply', true)),
    (v_tenant, v_conv_b, 'INBOUND', 'message:wamid.S8_B', 'TEXT', 'oi, quanto é a escova?',
     statement_timestamp() - interval '60 seconds', jsonb_build_object('agentMayReply', true));

  -- A automação do salão precisa estar ligada, senão a fila estaria vazia por
  -- outro motivo e o teste passaria sem provar nada.
  insert into app.agent_automation (tenant_id, enabled, changed_at, changed_by_email, reason)
  values (v_tenant, true, statement_timestamp(), 's8@teste', 'S8')
  on conflict (tenant_id) do update set enabled = true;

  select count(*) into v_na_fila from app.list_conversations_awaiting_agent(50, 25)
   where conversation_id in (v_conv_a, v_conv_b);
  if v_na_fila <> 2 then
    raise exception 'esperava as duas conversas na fila antes da pausa, vieram %', v_na_fila;
  end if;

  -- 1. Pausa a A.
  v_resultado := app.set_conversation_pause(v_tenant, v_conv_a, true, 's8@teste', 'assumindo');
  if coalesce((v_resultado->>'ok')::boolean, false) is not true then
    raise exception 'set_conversation_pause recusou: %', v_resultado;
  end if;

  select count(*) into v_na_fila from app.list_conversations_awaiting_agent(50, 25)
   where conversation_id = v_conv_a;
  if v_na_fila <> 0 then
    raise exception 'a conversa pausada continuou na fila';
  end if;

  -- 3. A B, do mesmo salão, não pode ter sido afetada. É o ponto do teste.
  select count(*) into v_na_fila from app.list_conversations_awaiting_agent(50, 25)
   where conversation_id = v_conv_b;
  if v_na_fila <> 1 then
    raise exception 'pausar uma conversa calou a outra: isso é o botão de emergência, não a pausa';
  end if;

  -- 2. Despausar devolve a conversa.
  perform app.set_conversation_pause(v_tenant, v_conv_a, false, 's8@teste', null);
  select count(*) into v_na_fila from app.list_conversations_awaiting_agent(50, 25)
   where conversation_id = v_conv_a;
  if v_na_fila <> 1 then
    raise exception 'a conversa não voltou para a fila ao despausar';
  end if;

  -- Conversa que não existe é recusada com motivo, não com exceção crua.
  v_resultado := app.set_conversation_pause(v_tenant, gen_random_uuid(), true, 's8@teste', null);
  if v_resultado->>'reason' <> 'CONVERSATION_NOT_FOUND' then
    raise exception 'esperava CONVERSATION_NOT_FOUND para conversa inexistente, veio %', v_resultado;
  end if;
end $$;

select 'S8 OK: a pausa tira a conversa da fila, devolve ao despausar, e não toca nas outras' as resultado;

rollback;
