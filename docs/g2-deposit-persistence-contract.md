# G2 — Contrato de persistência do sinal

**Estado:** implementado localmente em migrations; não aplicado nem verificado no Supabase DEV nesta etapa.

## Escopo efetivado

A persistência acrescenta a condição `PENDING_SIGNAL` ao agendamento e conserva as ocupações já convertidas enquanto o sinal estiver pendente. A migration cria uma política de sinal por serviço e versão de configuração publicada, porém a interface administrativa para configurar essa política continua fora deste artefato. A origem usada no cálculo é o snapshot imutável da versão referenciada pelo hold, e não o rascunho atual.

| Registro                     | Garantia persistida                                                                                                    | Limite atual                                                            |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `service_deposit_policies`   | Política `NONE`, fixa ou percentual vinculada a uma versão publicada e a um serviço.                                   | Não há RPC ou tela administrativa nesta migration.                      |
| `appointment_deposits`       | Um snapshot por agendamento, com política, valor, moeda, prazo e estado. Campos financeiros do snapshot são imutáveis. | Expiração e dispensa estão modeladas, mas ainda não possuem worker/RPC. |
| `appointment_deposit_events` | Evento idempotente por tenant, origem e referência opaca. O evento não pode ser alterado nem removido.                 | Só `MANUAL_VERIFIED` e `SYSTEM_CANCELLATION` são aceitos nesta versão.  |

## Contratos públicos adicionados ou alterados

| Operação                                 | Resultado                                                                                      | Autorização                      | Evidência                                                                              |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------- | -------------------------------------------------------------------------------------- |
| `schedule_confirm_hold`                  | Cria agendamento `CONFIRMED` ou `PENDING_SIGNAL` e um snapshot de depósito na mesma transação. | Tenant autenticado pelo gateway. | Retorno inclui `deposit` com estado, valor e prazo.                                    |
| `schedule_register_deposit_confirmation` | Registra confirmação manual, altera sinal para `CONFIRMED` e agenda para `CONFIRMED`.          | Somente `OWNER` ou `ADMIN`.      | Chave única `(tenant_id, event_source, external_event_ref)` e `idempotent` no retorno. |
| `schedule_cancel_appointment`            | Cancela ocupações, teste de mechas existente e sinal pendente.                                 | Tenant autenticado pelo gateway. | Evento de cancelamento e auditoria; não processa estorno.                              |

> **Não conectado:** não há provedor de pagamento, link de cobrança, expiração automática, reconciliação, WhatsApp ou interface. A confirmação manual registra somente uma verificação autorizada; não representa pagamento comprovado por integração externa.

## Segurança e privacidade

As três novas tabelas exigem `tenant_id`, têm RLS habilitada e forçada, não concedem acesso a `anon` ou `authenticated` e concedem acesso direto apenas a `service_role`. As operações públicas usam o verificador de identidade existente e as ações sensíveis deixam correlação, ator, resultado e metadados minimizados em `app.audit_logs`. As referências de evento são identificadores opacos; a migration não armazena cartão, comprovante, mensagem ou dado bancário.

## Validação ainda obrigatória

A criação local não prova que o SQL é aplicável no ambiente DEV. Antes de marcar G2 como concluído, devem ser executados o parse/aplicação das migrations, os testes de confirmação sem sinal, com sinal, retry idempotente, tenant cruzado e cancelamento, seguidos da auditoria remota somente de leitura.
