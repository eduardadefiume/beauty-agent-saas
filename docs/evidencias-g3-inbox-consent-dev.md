# Evidências G3 — Inbox WhatsApp e consentimento no Supabase DEV

**Data de verificação:** 17 de agosto de 2026  
**Ambiente:** Supabase DEV `hjghwryhphgusefyivbl`  
**Escopo desta evidência:** persistência multiempresa de inbox e consentimento, isolamento estrutural, deduplicação e validação reversível. Não inclui o webhook HTTP da Meta nem tráfego de WhatsApp real.

## Estado verificável

| Item | Estado | Evidência observável |
|---|---|---|
| Contrato G3 | Documentado e versionado | Migrations `20260817120000_g3_whatsapp_inbox_consent.sql` e `20260817121000_g3_inbox_integrity.sql` na branch `feature/saas-com-dashboard-completo`. |
| Executor | Implementado e publicado | `scripts/run-g3-integration.mjs`; chama exclusivamente a Management API autenticada, propaga HTTP/JSON inválido e exige o sentinela de sucesso. |
| Aplicação DEV | Aplicado | [GitHub Actions #32031224286](https://github.com/eduardadefiume/beauty-agent-saas/actions/runs/32031224286), concluído com sucesso; os dois arquivos de migration e a suíte SQL foram concluídos. |
| Teste de integração | Testado | A suíte reversível encerra com `G3_WHATSAPP_INBOX_CONSENT_INTEGRATION_OK` e usa `BEGIN`/`ROLLBACK`; não deixa os UUIDs de teste no DEV. |
| Auditoria estrutural | Testado por consulta somente leitura | [GitHub Actions #32031764278](https://github.com/eduardadefiume/beauty-agent-saas/actions/runs/32031764278) retornou `passed: true` em `2026-08-17T12:49:15.127Z`. |
| WhatsApp Cloud API | Não conectado | Não existe endpoint HTTP para validação de assinatura, recepção de webhook ou envio de mensagens Meta nesta fatia. |

## Controles que passaram

| Controle | Como foi comprovado |
|---|---|
| Tabelas do domínio | As cinco tabelas `app.whatsapp_channels`, `app.contacts`, `app.conversations`, `app.messages` e `app.customer_consents` existem no DEV. |
| Isolamento em banco | As cinco tabelas têm `tenant_id NOT NULL`, RLS habilitada e RLS forçada. |
| Privilégios | `anon` e `authenticated` não têm `SELECT`; `service_role` tem `SELECT`, `INSERT`, `UPDATE` e `DELETE` em cada tabela G3. |
| FK escopada por tenant | A suíte tenta relacionar conversa, mensagem e consentimento de um tenant a registros de outro; cada tentativa exige `foreign_key_violation`. |
| Deduplicação | O índice parcial único `messages_tenant_whatsapp_message_id_key` foi auditado como existente, único e parcial para `(tenant_id, whatsapp_message_id)` quando `whatsapp_message_id IS NOT NULL`; a suíte confirma rejeição de duplicata. |
| Atualização técnica | Os gatilhos `contacts_touch_updated_at` e `whatsapp_channels_touch_updated_at` foram auditados como ativos. |

## Limites e pendências

> Esta evidência não autoriza declarar o módulo G3 inteiro como concluído. Ela comprova apenas a camada de persistência e seus guardrails no DEV.

Ainda faltam o endpoint de webhook com validação de assinatura Meta, a ingestão idempotente de eventos reais, a projeção operacional no painel de inbox, a gestão de consentimento pela interface e um smoke test autorizado com o número piloto. Nenhum dado de cliente foi consultado pela auditoria estrutural.

## Rastreabilidade de publicação

| Commit | Conteúdo |
|---|---|
| `26bc08e` | Verificador estrutural G3 somente leitura. |
| `d039c3d` | Workflow de auditoria G3, com `concurrency.cancel-in-progress: true`. |

