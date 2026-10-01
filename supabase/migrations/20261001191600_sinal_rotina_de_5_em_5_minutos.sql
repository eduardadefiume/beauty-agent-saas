-- O sinal: a rotina de lembrete e prazo roda de 5 em 5 minutos (app.sinal_rotina).
select cron.unschedule('sinal-lembrete-e-prazo') where exists (select 1 from cron.job where jobname = 'sinal-lembrete-e-prazo');
select cron.schedule('sinal-lembrete-e-prazo', '*/5 * * * *', $c$ select app.sinal_rotina(); $c$);
