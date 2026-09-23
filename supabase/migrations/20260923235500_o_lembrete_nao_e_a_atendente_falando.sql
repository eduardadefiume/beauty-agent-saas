-- O LEMBRETE NAO E A ATENDENTE FALANDO.
--
-- 23/09/2026, decisao da Eduarda, pedida duas vezes depois de eu levantar a
-- questao duas vezes.
--
-- Quando escrevi `enqueue_outbound_template` eu fiz o lembrete respeitar
-- `agent_automation_enabled` -- o mesmo interruptor que cala a atendente. O
-- raciocinio era: quem puxa o freio de emergencia quer o salao calado.
--
-- ELA DECIDIU O CONTRARIO, E O ARGUMENTO E MELHOR QUE O MEU: o freio existe
-- para quando o AGENTE esta escorregando -- inventando preco, entendendo
-- errado, respondendo o que nao devia. Lembrete de vespera nao e o agente
-- falando: e um texto fixo, aprovado pela Meta, sobre um horario que a propria
-- cliente marcou. Calar isso junto castiga a cliente por um problema que e do
-- agente. Ela chega no salao sem ter sido lembrada, ou nao chega.
--
-- E o caso em que mais doi e justamente o que o freio cria: a dona puxa o
-- freio as 15h porque o agente escorregou, passa a tarde consertando, e as 18h
-- ninguem e lembrado. No dia seguinte faltam tres clientes.
--
-- O QUE CONTINUA PODENDO PARAR O LEMBRETE, e sao tres coisas, nesta ordem:
--
--   1. `agent_scope.lembra_da_vespera` -- o interruptor do dono, por salao.
--      E o desligar normal, e nasce desligado.
--   2. `update app.agent_scope set lembra_da_vespera = false` sem `where` --
--      a parada geral, se um dia for preciso parar TODOS os saloes de uma vez.
--   3. `select cron.unschedule('lembrete-da-vespera')` -- o ultimo recurso,
--      que para o agendador inteiro sem mexer na escolha de nenhum dono.
--
-- Nao inventei um quarto interruptor proprio para isso. Interruptor que ninguem
-- lembra que existe e pior que interruptor nenhum: no dia do problema a pessoa
-- vai no que conhece.
--
-- O QUE NAO MUDA: `enqueue_outbound_message`, que e por onde a atendente fala,
-- continua respeitando o freio integralmente. A separacao e exatamente essa --
-- conversa passa pelo freio, lembrete nao.

create or replace function app.enqueue_outbound_template(
  p_tenant_id       uuid,
  p_conversation_id uuid,
  p_template_code   text,
  p_params          jsonb,
  p_idempotency_key text,
  p_preview         text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_modelo     record;
  v_conversa   record;
  v_message_id uuid;
  v_outbox_id  uuid;
  v_existente  record;
  v_params     jsonb := coalesce(p_params, '[]'::jsonb);
  v_quantos    integer;
begin
  if p_idempotency_key is null
     or length(trim(p_idempotency_key)) not between 8 and 128 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_IDEMPOTENCY_KEY');
  end if;

  if jsonb_typeof(v_params) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'PARAMS_NAO_E_LISTA');
  end if;

  -- AQUI FICAVA A TRAVA DO `agent_automation_enabled`, removida em 23/09/2026.
  -- O motivo esta no topo deste arquivo. Se alguem pensar em devolve-la, leia
  -- de la antes: a pergunta nao e tecnica, e sobre quem paga o preco.

  -- Idempotencia antes de tudo: o agendador roda de 15 em 15 minutos e vai
  -- encontrar o mesmo agendamento varias vezes no mesmo dia.
  select o.id, o.message_id, o.status into v_existente
    from app.outbox_messages o
   where o.tenant_id = p_tenant_id
     and o.idempotency_key = trim(p_idempotency_key);
  if found then
    return jsonb_build_object(
      'ok', true, 'duplicate', true,
      'outboxId', v_existente.id, 'messageId', v_existente.message_id,
      'status', v_existente.status
    );
  end if;

  select t.* into v_modelo
    from app.message_templates t
   where t.tenant_id = p_tenant_id
     and t.code = upper(trim(p_template_code));

  if not found then
    return jsonb_build_object(
      'ok', false, 'reason', 'MODELO_NAO_REGISTRADO',
      'codigo', upper(trim(p_template_code)),
      'comoResolver', 'Crie o modelo no WhatsApp Manager e registre com registrar_modelo_aprovado.');
  end if;

  if v_modelo.status <> 'APPROVED' then
    return jsonb_build_object(
      'ok', false, 'reason', 'MODELO_NAO_APROVADO', 'status', v_modelo.status);
  end if;

  v_quantos := jsonb_array_length(v_params);
  if v_quantos <> v_modelo.param_count then
    -- A Meta recusa a mensagem inteira quando a contagem nao bate, e o erro
    -- dela nao diz qual modelo era. Melhor recusar aqui, com o numero.
    return jsonb_build_object(
      'ok', false, 'reason', 'QUANTIDADE_DE_PARAMETROS_ERRADA',
      'esperado', v_modelo.param_count, 'recebido', v_quantos);
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

  -- O corpo legivel e so para a tela e para o historico. Quem decide o texto
  -- de verdade e a Meta, a partir do modelo aprovado.
  insert into app.crm_messages (
    tenant_id, conversation_id, direction, provider_message_id,
    message_type, body_text, occurred_at, metadata_minimized
  )
  values (
    p_tenant_id, p_conversation_id, 'OUTBOUND', null,
    'TEMPLATE', left(coalesce(p_preview, v_modelo.preview, v_modelo.template_name), 4096),
    statement_timestamp(),
    jsonb_build_object(
      'actor', 'SYSTEM',
      'deliveryStatus', 'PENDING',
      'templateCode', v_modelo.code,
      'templateName', v_modelo.template_name
    )
  )
  returning id into v_message_id;

  insert into app.outbox_messages (
    tenant_id, conversation_id, message_id, channel_connection_id,
    recipient_address, kind, body_text, template_name, template_language,
    template_params, actor, idempotency_key
  )
  values (
    p_tenant_id, p_conversation_id, v_message_id, v_conversa.channel_connection_id,
    v_conversa.address_normalized, 'TEMPLATE',
    left(coalesce(p_preview, v_modelo.preview, ''), 4096),
    v_modelo.template_name, v_modelo.language, v_params, 'SYSTEM',
    trim(p_idempotency_key)
  )
  returning id into v_outbox_id;

  update app.crm_conversations
     set last_message_at = greatest(last_message_at, statement_timestamp()),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id and id = p_conversation_id;

  -- Mesmo acordar de 23/09: o erro e engolido porque o cron de 30 segundos
  -- pega logo depois, e deixar o erro subir desfaria a gravacao da mensagem.
  begin
    perform app.tick_worker('ENVIO', 'whatsapp-sender', '{}'::jsonb, 60000);
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'ok', true, 'outboxId', v_outbox_id, 'messageId', v_message_id,
    'templateName', v_modelo.template_name);
end;
$fn$;

comment on function app.enqueue_outbound_template(uuid, uuid, text, jsonb, text, text) is
  'Enfileira um template aprovado. Nao checa a janela de 24h (e a razao de existir do template) nem o freio da atendente (decisao de 23/09/2026: lembrete nao e o agente falando). Quem desliga e agent_scope.lembra_da_vespera.';

revoke all on function app.enqueue_outbound_template(uuid, uuid, text, jsonb, text, text)
  from public, anon, authenticated;
grant execute on function app.enqueue_outbound_template(uuid, uuid, text, jsonb, text, text)
  to service_role;
