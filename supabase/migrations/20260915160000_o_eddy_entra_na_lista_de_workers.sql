-- O EDDY ENTRA NA LISTA DE WORKERS.
--
-- A dona mandou "Boa tarde" as 18:39:46, a mensagem entrou, caiu na fila do
-- Eddy -- e nada aconteceu. O cron dele rodava de minuto em minuto e falhava
-- calado, sempre igual:
--
--   new row for relation "worker_runs" violates check constraint
--   "worker_runs_worker_check" ... Failing row contains (..., EDDY, ...)
--
-- As duas tabelas de controle dos workers nasceram com a lista de nomes
-- escrita a mao no CHECK, e 'EDDY' nao estava nela. Pior: no `tick_worker` o
-- disparo HTTP vem ANTES desse insert, entao a transacao inteira voltava
-- atras e o pedido nem chegava a sair. Falha sem mensagem, sem tentativa e
-- sem rastro em lugar nenhum -- so em cron.job_run_details.
--
-- A lista continua fechada de proposito: ela e o que impede um nome errado
-- virar worker fantasma batendo em endpoint que nao existe. So passa a ter o
-- nome que faltava.

alter table app.worker_runs drop constraint worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY']));

alter table app.worker_heartbeat drop constraint worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY']));
