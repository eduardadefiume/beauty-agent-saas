-- O agendador precisa conhecer o worker novo. A lista e fechada de proposito:
-- e o que impede um tique com nome errado de virar corrida fantasma que nunca
-- liquida e trava o worker de verdade.
alter table app.worker_runs drop constraint if exists worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE', 'ENVIO', 'MIDIA', 'TOM']));

alter table app.worker_heartbeat drop constraint if exists worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE', 'ENVIO', 'MIDIA', 'TOM']));