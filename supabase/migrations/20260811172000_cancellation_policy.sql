begin;

-- Política de cancelamento configurável pelo dono do negócio: quando ativa,
-- vira parte da mensagem de confirmação enviada à cliente (junto com data e
-- horário do atendimento, preenchidos automático). Não processa cobrança
-- nenhuma sozinha, isso ainda depende de pagamento de verdade (por isso o
-- check em deposit_enabled continua travado nesta fase) — é só o texto de
-- aviso que a cliente recebe.
alter table app.configuration_drafts
  add column cancellation_policy_enabled boolean not null default false,
  add column cancellation_window_hours smallint not null default 24
    check (cancellation_window_hours between 1 and 168),
  add column cancellation_charge_type text
    check (cancellation_charge_type in ('FULL_PRICE', 'FIXED_AMOUNT', 'PERCENTAGE')),
  add column cancellation_charge_amount_minor integer
    check (cancellation_charge_amount_minor is null or cancellation_charge_amount_minor >= 0),
  add column cancellation_charge_percentage smallint
    check (cancellation_charge_percentage is null or cancellation_charge_percentage between 1 and 100);

commit;
