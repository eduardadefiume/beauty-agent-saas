-- A MENSAGEM ACORDA O AGENTE, EM VEZ DE ESPERAR O RELOGIO.
--
-- 23/09/2026. A dona reclamou que o Eddy demora. A conta, medida na conversa
-- real de hoje de manha:
--
--   12:56:11  a mensagem dela (carimbo da Meta)
--   12:57:00  o evento e PROJETADO           +49s   <- relogio
--   12:57:10  o Eddy decide                  +10s   <- pensando, isso e util
--   12:57:24  a resposta sai                 +14s   <- relogio (ja consertado)
--
-- Eu tinha dito a ela que os primeiros dez segundos eram o modelo pensando.
-- Estava olhando so o ultimo pedaco: o grosso era espera de relogio ANTES de
-- ele sequer ver a mensagem.
--
-- POR QUE DUAS ESPERAS. O webhook da Meta chega na hora e grava em
-- `inbox_events`. Mas quem transforma isso em conversa e mensagem e
-- `project_inbox_events`, que roda no cron `agente-whatsapp` a cada minuto. E
-- quem acorda o Eddy e o cron `eddy-do-dono`, tambem a cada minuto. Os dois
-- disparam no mesmo segundo do minuto e a ordem entre eles nao e garantida --
-- entao se o Eddy roda antes da projecao, ele nao ve nada e a mensagem espera
-- MAIS um minuto inteiro.
--
-- APERTAR O RELOGIO SERIA O CONSERTO ERRADO. Deixar o cron de dez em dez
-- segundos faria o worker acordar 8.640 vezes por dia para quase sempre nao
-- achar nada, e ainda assim deixaria ate dez segundos de atraso. O evento ja
-- existe: a mensagem chegando. E ela que tem que acordar quem trabalha.
--
-- O cron continua de pe, e isso e de proposito: ele passa a ser a rede de
-- seguranca para o caso de a chamada daqui falhar, nao mais o caminho normal.

create or replace function app.acordar_atendimento_agora()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_projetados integer;
  v_eddy   text;
  v_agente text;
begin
  -- 1. O que chegou vira conversa e mensagem AGORA, nao no proximo minuto.
  select app.project_inbox_events(200) into v_projetados;

  -- 2. E so entao os dois trabalhadores sao chamados -- nesta ordem, porque
  --    acordar antes de projetar e acordar para nao achar nada.
  --
  --    Os corpos sao copiados dos crons `eddy-do-dono` e `agente-whatsapp`
  --    de proposito: dois lugares com parametros diferentes para o mesmo
  --    worker viram dois comportamentos que ninguem consegue explicar depois.
  v_eddy := app.tick_worker('EDDY', 'eddy-agent', '{"limit": 5}'::jsonb, 150000);
  v_agente := app.tick_worker('AGENTE', 'whatsapp-agent',
                              '{"limit": 5, "quietSeconds": 25}'::jsonb, 150000);

  return jsonb_build_object(
    'ok', true, 'projetados', v_projetados, 'eddy', v_eddy, 'agente', v_agente
  );
exception when others then
  -- Nunca derrubar a entrada da mensagem por causa da pressa. Se acordar
  -- falhar, o cron pega no proximo minuto -- que e exatamente o que acontecia
  -- antes desta funcao existir.
  return jsonb_build_object('ok', false, 'reason', substr(sqlerrm, 1, 200));
end;
$fn$;

comment on function app.acordar_atendimento_agora() is
  'Projeta a caixa de entrada e acorda EDDY e AGENTE na hora em que a mensagem chega, em vez de esperar o cron de um minuto. O cron continua como rede de seguranca.';
revoke all on function app.acordar_atendimento_agora() from public, anon, authenticated;
grant execute on function app.acordar_atendimento_agora() to service_role;

-- A porta publica, sem a qual nada disso existe para a Edge Function.
-- (Licao de hoje de manha: nove ferramentas viveram dois dias sem esta linha.)
create or replace function public.acordar_atendimento_agora()
returns jsonb language sql security definer set search_path to ''
as $$ select app.acordar_atendimento_agora(); $$;
revoke all on function public.acordar_atendimento_agora() from public, anon, authenticated;
grant execute on function public.acordar_atendimento_agora() to service_role;
