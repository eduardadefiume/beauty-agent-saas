-- O agente consultava a agenda e nunca conseguia marcar.
--
-- Prova: teste do dia 31/08 com a Eduarda. Ela aceitou sabado 05/09 as 8h, o
-- agente achou o horario, chamou reservar_horario e recebeu
-- SITE_TENANT_NOT_ACCESSIBLE. Nenhuma linha entrou em app.schedule_holds. O
-- agente entao foi perguntar a dona se podia confirmar assim mesmo -- que e
-- exatamente o desfecho que nao pode existir.
--
-- Causa: das onze RPCs de agenda, schedule_create_hold e a UNICA que restringe
-- papel, e restringe a OWNER e ADMIN. Todas as outras -- inclusive
-- schedule_confirm_hold e schedule_cancel_appointment, que fazem mais estrago
-- que segurar um horario -- passam null e aceitam qualquer papel do tenant.
-- A identidade de servico do agente (agente@sistema.interno) e OPERATOR, que e
-- o papel de quem atende no balcao e anota horario. Ou seja: a restricao mais
-- apertada do conjunto estava justamente na porta que o agente precisa.
--
-- Correcao: OPERATOR entra na lista. VIEWER continua de fora -- quem so olha
-- nao segura horario. Nao promovo o agente a ADMIN: isso abriria junto o
-- catalogo, as politicas e o resto do console para ele.
--
-- A troca e cirurgica de proposito. Em vez de reescrever uma funcao longa
-- inteira (e arriscar mudar o que nao quero), leio a definicao viva, troco so
-- a lista de papeis e reaplico. Se a lista nao estiver la do jeito esperado, a
-- migracao falha em vez de alterar outra coisa.
do $$
declare
  antes    constant text := 'array[''OWNER''::app.tenant_role, ''ADMIN''::app.tenant_role]';
  depois   constant text := 'array[''OWNER''::app.tenant_role, ''ADMIN''::app.tenant_role, ''OPERATOR''::app.tenant_role]';
  definicao text;
begin
  select pg_get_functiondef(p.oid)
    into definicao
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'schedule_create_hold';

  if definicao is null then
    raise exception 'public.schedule_create_hold nao existe';
  end if;

  if position(depois in definicao) > 0 then
    raise notice 'OPERATOR ja podia segurar horario, nada a fazer';
    return;
  end if;

  if position(antes in definicao) = 0 then
    raise exception 'a lista de papeis de schedule_create_hold nao esta como esperado; nada foi alterado';
  end if;

  execute replace(definicao, antes, depois);
end $$;
