-- O VIGIA OLHA O QUE SAIU, NÃO A MARCA (07/10/2026).
--
-- Na prova da migração anterior, o vigia não pegou o "o 1" do William no DEV:
-- a mensagem tinha agentDecision = REPLY. O Eddy respondeu cinco dias depois
-- (crédito acabado), a janela de 24h já tinha fechado e o envio foi RECUSADO
-- -- mas o código não conferia o resultado e marcou REPLY. O vigia confiava
-- na marca. Agora: última mensagem é da pessoa e passou 15 min = sem
-- resposta, qualquer que seja a marca (menos HANDOFF, que tem alerta próprio).
-- E o código (Eddy e atendente) passa a avisar RESPOSTA_NAO_ENVIADA na hora.

create or replace function app.recado_do_problema(p_kind text)
returns text language sql immutable
as $fn$
  select case p_kind
    when 'SEM_CREDITO'            then 'O agente parou de responder: acabou o crédito da IA. Ele volta sozinho assim que você recarregar.'
    when 'CHAVE_DA_IA_INVALIDA'   then 'O agente parou de responder: a chave da IA foi recusada. Precisa ser trocada na configuração.'
    when 'IA_OCUPADA'             then 'A IA está sobrecarregada e o agente está demorando para responder. Costuma passar sozinho em alguns minutos.'
    when 'TOKEN_DO_WHATSAPP'      then 'O WhatsApp recusou o acesso do agente. O token do número precisa ser renovado.'
    when 'AGENTE_FALHANDO'        then 'O agente está falhando seguido em pelo menos uma conversa. Vale olhar as conversas paradas.'
    when 'PEDIDO_FORA_DO_ALCANCE' then 'O Eddy passou um pedido do dono para uma pessoa (algo que ele não soube ou não pôde fazer).'
    when 'RESPOSTA_BLOQUEADA'     then 'A atendente escreveu algo sem base (horário ou preço) e a trava segurou. A cliente não recebeu o erro, mas a conversa precisa de alguém.'
    when 'PASSOU_PARA_PESSOA'     then 'A atendente passou uma conversa para uma pessoa. Alguém precisa responder a cliente.'
    when 'SEM_RESPOSTA'           then 'Uma mensagem está há mais de 15 minutos sem resposta. Alguém precisa responder.'
    when 'RESPOSTA_NAO_ENVIADA'   then 'O agente escreveu a resposta, mas o WhatsApp recusou o envio. A pessoa não recebeu nada.'
    else 'O agente encontrou um problema.'
  end;
$fn$;

create or replace function app.alerta_de_uma_vez(p_kind text)
returns boolean language sql immutable
as $fn$
  select coalesce(p_kind in ('PEDIDO_FORA_DO_ALCANCE', 'RESPOSTA_BLOQUEADA', 'PASSOU_PARA_PESSOA',
                             'SEM_RESPOSTA', 'RESPOSTA_NAO_ENVIADA'), false);
$fn$;

-- Quem deveria ter respondido e não respondeu. Fica de fora o que é normal
-- esperar: conversa pausada (uma pessoa assumiu), salão com a atendente
-- desligada (exceto a conversa do dono, que é do Eddy), pergunta já passada
-- à dona (ASK_OWNER manda aviso à cliente, então a última já não é dela),
-- canal desligado.
create or replace function app.mensagens_sem_resposta(p_minutos integer default 15)
returns table (message_id uuid, tenant_id uuid, conversation_id uuid, desde timestamptz, quem text)
language sql
stable
security definer
set search_path to ''
as $function$
  with ultima as (
    select distinct on (m.tenant_id, m.conversation_id)
           m.id, m.tenant_id, m.conversation_id, m.direction, m.occurred_at,
           coalesce(m.metadata_minimized->>'agentDecision', '') as decisao
      from app.crm_messages m
     where m.occurred_at > statement_timestamp() - interval '7 days'
       and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
     order by m.tenant_id, m.conversation_id, m.occurred_at desc
  )
  select u.id, u.tenant_id, u.conversation_id, u.occurred_at,
         case when app.conversa_e_do_dono(u.conversation_id) then 'dono' else 'cliente' end
    from ultima u
    join app.crm_conversations c on c.tenant_id = u.tenant_id and c.id = u.conversation_id
    join app.channel_connections ch on ch.id = c.channel_connection_id and ch.tenant_id = c.tenant_id
   where u.direction = 'INBOUND'
     -- Olha o que saiu, não a marca: REPLY sem mensagem depois é silêncio
     -- (07/10: envio recusado pela janela de 24h). HANDOFF já tem alerta próprio.
     and u.decisao <> 'HANDOFF'
     and u.occurred_at < statement_timestamp() - make_interval(mins => greatest(coalesce(p_minutos, 15), 1))
     and ch.status not in ('DISCONNECTED', 'SUSPENDED')
     and not app.e_da_operadora(c.external_conversation_ref)
     and (app.conversa_e_do_dono(u.conversation_id) or app.agent_automation_enabled(u.tenant_id))
     and not exists (
       select 1 from app.agent_conversation_pause p
        where p.tenant_id = u.tenant_id and p.conversation_id = u.conversation_id and p.paused)
     and not exists (
       select 1 from app.mensagens_sem_resposta_avisadas a where a.message_id = u.id);
$function$;

revoke all on function app.mensagens_sem_resposta(integer) from public, anon, authenticated;
