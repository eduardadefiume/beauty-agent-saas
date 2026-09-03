-- A fila do histórico acorda sozinha.
--
-- De cinco em cinco minutos, e não de dois em dois como a leitura de foto: um
-- arquivo de dois anos leva alguns segundos para ser lido e gravado, e não há
-- nenhuma pressa. Cliente esperando resposta é urgente; arquivo de importação
-- não é.
--
-- Os dois `check` de worker precisam do valor novo. Vão na mesma migração
-- porque, separados, o primeiro passa e o segundo derruba -- e aí o `tick`
-- registra a corrida e falha ao bater o coração.

alter table app.worker_runs drop constraint if exists worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE', 'ENVIO', 'MIDIA', 'TOM', 'HISTORICO']));

alter table app.worker_heartbeat drop constraint if exists worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE', 'ENVIO', 'MIDIA', 'TOM', 'HISTORICO']));

select cron.schedule(
  'historico-do-whatsapp',
  '*/5 * * * *',
  $cron$
  select app.tick_worker('HISTORICO', 'whatsapp-history-reader', '{"limit": 3}'::jsonb, 180000);
$cron$
);
