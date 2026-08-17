# G2 — Expiração idempotente de sinal e testes de integração v1

**Status:** especificado para implementação. Este documento não comprova aplicação no banco ou execução da suíte.

## 1. Escopo

Esta fatia fecha a transição que faltava para um agendamento com sinal pendente e prazo vencido. Ela não integra pagamento, WhatsApp, CRM, campanhas nem configura um processo de execução permanente. O mecanismo entregue será uma rotina SQL invocável exclusivamente por serviço interno; a definição de quando ela será disparada automaticamente permanece dependente da infraestrutura de automação aprovada.

## 2. Requisitos verificáveis

| ID      | Regra                                                                                                                                                                 |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G2-E-01 | Apenas depósitos `PENDING` com `due_at` estritamente anterior ao instante da rotina podem expirar.                                                                    |
| G2-E-02 | A expiração altera, na mesma transação, o depósito para `EXPIRED`, o agendamento `PENDING_SIGNAL` para `CANCELLED` e as ocupações ativas associadas para `CANCELLED`. |
| G2-E-03 | Cada expiração gera exatamente um evento imutável `SYSTEM_EXPIRATION`, com chave idempotente determinística por depósito.                                             |
| G2-E-04 | Reexecução, concorrência e lote vazio não duplicam eventos, não reabrem ocupações e não degradam estados terminais.                                                   |
| G2-E-05 | Depósitos futuros, confirmados, dispensados e cancelados não podem ser expirados pela rotina.                                                                         |
| G2-E-06 | A execução somente é concedida a `service_role`; dados de cliente, dados de pagamento e dados de contato não são gravados no evento ou no log.                        |
| G2-E-07 | A rotina registra auditoria por agendamento com tenant, correlação, ator `WORKER`, resultado e metadados minimizados.                                                 |

## 3. Modelagem

Não será criada uma nova tabela. A transição usa as entidades existentes e estende a lista permitida de `event_source` em `app.appointment_deposit_events` com `SYSTEM_EXPIRATION`.

| Origem                      | Estado do depósito    | Estado do agendamento          | Efeito no ledger                                       |
| --------------------------- | --------------------- | ------------------------------ | ------------------------------------------------------ |
| `SYSTEM_EXPIRATION`         | `PENDING` → `EXPIRED` | `PENDING_SIGNAL` → `CANCELLED` | Ocupações de `APPOINTMENT` ativas passam a `CANCELLED` |
| Reexecução do mesmo lote    | `EXPIRED`             | `CANCELLED`                    | Nenhum efeito adicional                                |
| Depósito futuro ou terminal | Sem alteração         | Sem alteração                  | Nenhum efeito                                          |

## 4. Arquitetura

A migration adicionará `public.schedule_expire_due_deposits(target_correlation_id, target_limit)`. Ela será `SECURITY DEFINER`, usará `FOR UPDATE SKIP LOCKED`, terá limite explícito de lote e ficará sem acesso para `public`, `anon` e `authenticated`. A execução será possível apenas para `service_role`.

A rotina varre depósitos vencidos `PENDING` vinculados a agendamentos `PENDING_SIGNAL`, bloqueia cada linha e aplica a transição atômica. A referência idempotente será derivada de `appointment_deposit_id` com o sufixo estável `:expired`; portanto, uma repetição não pode registrar dois eventos para o mesmo depósito. As ocupações e os registros de teste de mechas seguem o mesmo efeito de cancelamento já adotado no contrato de cancelamento manual.

> A rotina **não é um agendador**. Ela torna a expiração segura e executável. O acionamento automático exige uma infraestrutura persistente separada; criar um cron improvisado no ambiente atual seria declarar automação onde ela não existe.

## 5. Matriz de testes de integração

| Cenário           | Prova esperada                                                                                                                                                 |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Depósito vencido  | Estados mudam para `EXPIRED` e `CANCELLED`; ocupações são liberadas; evento e auditoria existem.                                                               |
| Reexecução        | Segunda chamada não altera o estado nem cria novo evento.                                                                                                      |
| Prazo futuro      | Estado permanece `PENDING_SIGNAL`/`PENDING`; ocupação permanece ativa.                                                                                         |
| Estado terminal   | Depósito confirmado ou cancelado permanece inalterado mesmo com prazo passado.                                                                                 |
| Concorrência/lote | `SKIP LOCKED` e a chave única impedem efeito duplicado; o lote respeita o limite informado.                                                                    |
| Isolamento        | As tabelas de sinal mantêm RLS forçada, nenhum privilégio direto é concedido a `authenticated` e a função de expiração só pode ser chamada por `service_role`. |

## 6. Backlog desta fatia

1. Criar migration isolada de expiração e de concessões da rotina.
2. Criar script SQL transacional de integração, com `ROLLBACK` obrigatório.
3. Criar executor de teste e auditoria somente leitura para o Supabase DEV.
4. Aplicar a migration no DEV e executar os testes por pipeline controlado.
5. Registrar o resultado e manter a automação recorrente como pendência de infraestrutura.
