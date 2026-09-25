-- RESPOSTA DO DONO NAO GERA UM SEGUNDO TURNO NA MESMA RODADA.
--
-- 25/09/2026, cliente-robo Renata. Ela mandou mensagem nova e, no mesmo
-- minuto, o dono respondeu a pergunta dela (estacionamento). A fila devolveu
-- a conversa DUAS vezes: NOVA_MENSAGEM e RESPOSTA_DO_DONO. O primeiro turno
-- ja leu a resposta do dono e respondeu tudo; o segundo, sem nada novo,
-- mandou "Ja te mandei essa pergunta e voce ainda nao respondeu, entao deixa
-- comigo assim que puder :)" -- quatro segundos depois.
--
-- Quando ha mensagem nova, ela ja carrega a resposta do dono (o contexto le
-- as respostas e consume_owner_answers fecha depois de qualquer turno). A
-- retomada so entra quando nao ha mensagem nova.

do $mig$
declare
  v_def text := pg_get_functiondef('app.list_conversations_awaiting_agent(integer, integer)'::regprocedure);
  c_ancora constant text := E'    select * from novas\n    union\n    select * from retomadas\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de list_conversations_awaiting_agent sumiu';
  end if;
  execute replace(v_def, c_ancora,
       E'    select * from novas\n'
    || E'    union\n'
    || E'    select * from retomadas r\n'
    || E'     where not exists (select 1 from novas n\n'
    || E'                        where n.tenant_id = r.tenant_id\n'
    || E'                          and n.conversation_id = r.conversation_id)\n');
end
$mig$;

revoke all on function app.list_conversations_awaiting_agent(integer, integer) from public, anon, authenticated;
