-- VIGIA DE MENSAGEM SEM RESPOSTA + MODELOS NO WHATSAPP SIMULADO.
--
-- 07/10/2026, conferência antes do teste do William:
--
-- 1. O "o 1" do William no DEV (02/10) nunca foi respondido e ninguém soube.
--    O crédito voltou em 07/10, mas a fila da atendente só olha conversa com
--    mensagem nas últimas 24h (fora disso o WhatsApp nem aceita texto livre).
--    Qualquer motivo que segure uma resposta além disso -- falha longa, fila
--    travada, função fora do ar -- some calado. Em vez de tapar cada motivo,
--    um vigia olha o resultado: mensagem de cliente ou dono que ficou 15 min
--    sem resposta vira alerta para a operadora, uma vez por mensagem.
--
-- 2. No DEV, o "✅ Resolvido" do crédito nunca saiu: MODELO_NAO_REGISTRADO.
--    O canal simulado não tem modelos da Meta, e passadas 24h todo aviso
--    caía no vazio -- inclusive lembrete e sinal, que nunca puderam ser
--    testados fora da janela. O canal simulado ganha os mesmos modelos da
--    produção, aprovados (não há Meta para aprovar). Na produção, onde não
--    existe canal simulado, esta parte não faz nada.

-- ---------------------------------------------------------------------------
-- 1. O VIGIA
-- ---------------------------------------------------------------------------
create table if not exists app.mensagens_sem_resposta_avisadas (
  message_id  uuid primary key,
  tenant_id   uuid not null references app.tenants(id) on delete cascade,
  avisada_em  timestamptz not null default statement_timestamp()
);

alter table app.mensagens_sem_resposta_avisadas enable row level security;

comment on table app.mensagens_sem_resposta_avisadas is
  'Mensagens que ficaram sem resposta e já viraram alerta (uma vez por mensagem).';

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
    else 'O agente encontrou um problema.'
  end;
$fn$;

create or replace function app.alerta_de_uma_vez(p_kind text)
returns boolean language sql immutable
as $fn$
  select coalesce(p_kind in ('PEDIDO_FORA_DO_ALCANCE', 'RESPOSTA_BLOQUEADA', 'PASSOU_PARA_PESSOA', 'SEM_RESPOSTA'), false);
$fn$;

-- Quem deveria ter respondido e não respondeu. Fica de fora o que é normal
-- esperar: conversa pausada (uma pessoa assumiu), salão com a atendente
-- desligada (exceto a conversa do dono, que é do Eddy), pergunta já passada
-- à dona (ASK_OWNER marca agentDecision), canal desligado.
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
           (m.metadata_minimized ? 'agentDecision') as decidida
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
     and not u.decidida
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

create or replace function app.vigiar_sem_resposta()
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_m  record;
  v_n  integer := 0;
  v_quem text;
begin
  for v_m in select * from app.mensagens_sem_resposta(15) limit 20 loop
    select case when v_m.quem = 'dono' then 'o dono (Eddy)'
                else 'a cliente final ' || right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 4)
           end
      into v_quem
      from app.crm_conversations c where c.id = v_m.conversation_id;

    insert into app.mensagens_sem_resposta_avisadas (message_id, tenant_id)
    values (v_m.message_id, v_m.tenant_id)
    on conflict do nothing;

    -- Um alerta aberto por salão: a segunda conversa parada antes do envio
    -- soma ocorrência no mesmo alerta, e o detalhe mostra a última.
    perform app.raise_agent_alert(
      v_m.tenant_id, 'SEM_RESPOSTA',
      'Quem espera: ' || coalesce(v_quem, '?') || ', desde '
      || to_char(v_m.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
      || ' [conversa ' || left(v_m.conversation_id::text, 8) || ']');
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

-- O vigia roda junto com o aviso, no mesmo minuto e antes dele.
select cron.unschedule('avisar-operadora');
select cron.schedule('avisar-operadora', '* * * * *',
  $c$ select app.vigiar_sem_resposta(); select app.avisar_operadora(); $c$);

-- ---------------------------------------------------------------------------
-- 2. MODELOS NO CANAL SIMULADO (só existe no DEV)
-- ---------------------------------------------------------------------------
insert into app.message_templates
       (tenant_id, code, template_name, language, category, status, param_count, preview)
select distinct ch.tenant_id, m.code, m.nome, 'pt_BR', 'UTILITY', 'APPROVED', m.n, m.preview
  from app.channel_connections ch
 cross join (values
   ('LEMBRETE_VESPERA', 'lembrete_vespera', 4,
    'Olá, {{1}}! Passando para lembrar do seu horário amanhã, {{2}}, às {{3}}, no {{4}}. Se precisar remarcar, é só responder esta mensagem.'),
   ('AVISO_AO_DONO', 'aviso_ao_dono', 4,
    'Olá! A atendente do {{1}} precisa de uma resposta sua sobre a cliente {{2}}. Pergunta: {{3}} (código {{4}}). Responda esta mensagem que eu passo a resposta para ela.'),
   ('LEMBRETE_DO_SINAL', 'lembrete_do_sinal', 5,
    'Olá, {{1}}! Passando para lembrar do sinal de R$ {{2}} do seu horário ({{3}}). Ele vence {{4}}. Chave Pix: {{5}}. Sem o sinal o horário não fica garantido; se já pagou, é só mandar o comprovante aqui.'),
   ('SINAL_VENCEU', 'sinal_venceu', 2,
    'Olá, {{1}}! O prazo do sinal do seu horário ({{2}}) venceu e, como combinado, o horário foi liberado. Se ainda quiser fazer, responda esta mensagem que eu vejo outro horário para você.'),
   ('ALERTA_DA_OPERACAO', 'alerta_da_operacao', 3,
    'Alerta do sistema no {{1}}: {{2}} (código {{3}}). Responda esta mensagem para receber os próximos alertas completos.')
 ) as m(code, nome, n, preview)
 where ch.simulado
   and not exists (
     select 1 from app.message_templates t where t.tenant_id = ch.tenant_id and t.code = m.code);

revoke all on function app.mensagens_sem_resposta(integer) from public, anon, authenticated;
revoke all on function app.vigiar_sem_resposta() from public, anon, authenticated;
