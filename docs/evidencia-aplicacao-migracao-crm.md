# Evidência de aplicação — migração CRM

## Ambiente

| Item | Valor |
|---|---|
| Ambiente | Supabase DEV — `hjghwryhphgusefyivbl` |
| Migração | `20260813114500_crm_inbox_campaigns_base.sql` |
| Escopo | Base de dados CRM, consentimentos e campanhas governadas |
| Estado em 13/08/2026 | Em aplicação controlada pelo editor SQL autenticado |

## Controle

A migração é transacional (`begin`/`commit`) e foi revisada antes da execução. Ela cria apenas os tipos, tabelas, índices, triggers, políticas de acesso e privilégios necessários ao CRM inicial; não cria dados de cliente nem dispara campanhas.

> Esta evidência só deve ser atualizada para **aplicada** após retorno explícito de sucesso no ambiente DEV e validação das tabelas criadas.

## Registro de execução

Em 13/08/2026, o editor SQL autenticado foi aberto e a migração foi preparada para execução. A automação de navegador bloqueou a inserção programática de conteúdo no Monaco e preservou apenas o caractere de teste no editor.

Uma primeira tentativa pela API oficial de gerenciamento foi rejeitada por erro de sintaxe causado por corrupção na cópia de uma referência de chave estrangeira antes do envio. Como a migração está encapsulada em transação, a tentativa foi abortada e **nenhuma alteração foi persistida no banco**. A próxima execução deve transmitir diretamente o arquivo canônico, sem cópia manual.

Após a tentativa rejeitada, a sessão automatizada do navegador foi reinicializada. Não houve novo envio de SQL, nem qualquer modificação adicional no ambiente DEV.

## Resultado

| Verificação | Evidência |
|---|---|
| Execução | API oficial de gerenciamento do Supabase autenticada pela sessão do proprietário |
| Resultado | `201 Created` com corpo `[]` |
| Tamanho transmitido | 10.573 caracteres, iniciando em `begin;` e terminando em `commit;` |
| Estado | **Aplicada em Supabase DEV** em 13/08/2026 |

Não foram criados contatos, mensagens, consentimentos ou campanhas. A execução instalou apenas a estrutura de dados, os índices, os triggers e as restrições de acesso previstos na migração canônica.

## Validação pós-migração

A consulta ao catálogo PostgreSQL confirmou as sete relações planejadas — `crm_contacts`, `crm_contact_channels`, `crm_conversations`, `crm_messages`, `crm_contact_consents`, `campaigns` e `campaign_recipients` — todas com `rls_enabled = true` e `rls_forced = true`.
