-- A mensagem chegava e parava.
--
-- O caminho de uma mensagem de cliente tem quatro passos: webhook grava o
-- evento cru em app.inbox_events, app.project_inbox_events transforma esse
-- evento em conversa e mensagem do CRM, o agente le a conversa e escreve a
-- resposta, o envio entrega. Quando montei o relogio dos workers eu agendei o
-- terceiro e o quarto passo e esqueci o segundo -- ele vinha sendo chamado a
-- mao durante os testes, e a mao some quando o sistema fica sozinho.
--
-- O sintoma era o pior possivel: nada de errado em lugar nenhum. O webhook
-- respondia 200, o evento ficava PENDING para sempre, e o agente reportava
-- "aguardando: 0" com toda a razao -- nao havia conversa nenhuma esperando,
-- porque ninguem tinha criado.
--
-- A projecao entra no MESMO comando do agente, antes dele, e nao num job
-- proprio. Dois jobs separados no mesmo minuto nao tem ordem garantida: a
-- mensagem podia ser projetada logo depois do agente ter olhado a fila, e
-- esperaria mais um minuto sem motivo. No mesmo comando a ordem e certa --
-- projeta, depois olha. Nao custa latencia: a cadencia do agente ja e de um
-- minuto, entao projetar mais rapido nao adiantaria nada.
--
-- O lote e de 200. O padrao da funcao e 100 e o teto e 1000; 200 da folga
-- para uma rajada sem transformar um minuto de cron numa transacao longa.

select cron.unschedule('agente-whatsapp');

select cron.schedule(
  'agente-whatsapp',
  '* * * * *',
  $cron$
  select app.project_inbox_events(200);
  select app.tick_worker('AGENTE', 'whatsapp-agent', '{"limit": 5, "quietSeconds": 25}'::jsonb, 150000);
  $cron$
);
