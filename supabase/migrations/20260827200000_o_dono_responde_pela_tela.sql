-- O dono responde pela tela.
--
-- POR QUE ISTO É OBRIGATÓRIO E NÃO CONFORTO. Um número que entra na Cloud API
-- SAI do aplicativo do WhatsApp Business -- é uma coisa ou outra, nunca as
-- duas. No dia em que o número do William migrar, o aplicativo dele para de
-- funcionar. Se a tela não tiver caixa de digitação, ele fica sem nenhuma
-- forma de falar com a cliente dele. Até aqui a tela só mostrava o que o
-- agente respondeu; era um espelho, e espelho não serve de telefone.
--
-- O encanamento de envio já existia inteiro: app.enqueue_outbound_message põe
-- na outbox, o worker ENVIO entrega, e o ator HUMAN já passa mesmo com a
-- parada de emergência ligada -- porque a parada cala o robô, não o salão.
-- Faltava só a porta pela qual a tela chama isso.
--
-- A JANELA DE 24 HORAS NÃO É ESCOLHA NOSSA. A Meta só aceita texto livre nas
-- 24h seguintes à última mensagem da cliente. Fora disso, só modelo aprovado.
-- A função devolve SERVICE_WINDOW_CLOSED em vez de fingir que enviou, e a tela
-- mostra isso na cara -- botão que parece funcionar e não funciona é pior que
-- botão desligado.
--
-- A chave de idempotência vem do cliente e não do servidor de propósito: se a
-- conexão cair depois do envio e o dono apertar de novo, a mesma chave devolve
-- o mesmo envio em vez de mandar a mensagem duas vezes para a cliente.

create or replace function public.site_send_manual_message(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_conversation_id uuid,
  message_text           text,
  idempotency_key        text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_resultado jsonb;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  if message_text is null or length(trim(message_text)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_BODY');
  end if;
  -- Teto de 4096 é o da própria Meta. Cortar aqui evita descobrir o limite
  -- pelo erro da API depois que a mensagem já entrou na fila.
  if length(message_text) > 4096 then
    return jsonb_build_object('ok', false, 'reason', 'BODY_TOO_LONG');
  end if;

  v_resultado := app.enqueue_outbound_message(
    p_tenant_id       => target_tenant_id,
    p_conversation_id => target_conversation_id,
    p_body_text       => message_text,
    p_actor           => 'HUMAN'::app.outbound_actor,
    p_idempotency_key => idempotency_key
  );

  return v_resultado;
end;
$function$;

revoke all on function public.site_send_manual_message(text, text, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.site_send_manual_message(text, text, uuid, uuid, text, text)
  to service_role;
