begin;

-- Teste de mechas (strand test): alguns serviços de coloração exigem um
-- teste curto antes do atendimento principal, feito na semana anterior,
-- de preferência quinta ou sexta. Esta migration só guarda a CONFIGURAÇÃO
-- desse requisito por serviço — o agendamento automático do teste em si
-- (achar e reservar o horário do teste, ligado ao agendamento principal)
-- ainda não está no motor de busca; fica para uma próxima etapa, depois de
-- decidir com a Duda regras como "precisa ser a mesma colorista?" e "o que
-- acontece se não achar horário de teste na janela?".
alter table app.services
  add column requires_strand_test boolean not null default false,
  add column strand_test_lead_days smallint not null default 7 check (strand_test_lead_days between 1 and 30),
  add column strand_test_duration_minutes smallint not null default 60 check (strand_test_duration_minutes between 10 and 240),
  add column strand_test_preferred_weekdays smallint[] not null default '{4,5}'
    check (strand_test_preferred_weekdays <@ array[0,1,2,3,4,5,6]::smallint[]);

commit;
