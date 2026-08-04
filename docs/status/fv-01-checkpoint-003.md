# FV-01 — checkpoint 003

**Data:** 04 de agosto de 2026  
**Estado:** `IN_PROGRESS`  
**Rótulo:** banco DEV migrado e testado; integrações externas `MOCK`; PROD intocado

## Entregue nesta rodada

- Conector Supabase reconciliado com os projetos exclusivos do SaaS.
- Migration base aplicada somente em `agente-beleza-saas-dev`.
- Hardening de privilégios aplicado e versionado.
- Cinco tabelas de negócio em `app`, todas com RLS ativo e zero dados permanentes.
- Smoke test transacional com dois tenants executado e revertido.
- Leitura e escrita cross-tenant negadas.
- Execução de `public.rls_auto_enable()` negada a `anon` e `authenticated`.
- Advisors de segurança sem alertas após o hardening.
- Avaliação do `quauhtlimtz/whatsapp-mcp` registrada em ADR-002.
- Migration history e nomes de arquivos reconciliados: `20260804172009` e `20260804172122`.

## Evidência do Supabase DEV

| Verificação | Resultado |
|---|---|
| Projeto | `agente-beleza-saas-dev` — `ACTIVE_HEALTHY` |
| Migration base | Aplicada |
| Migration de hardening | Aplicada |
| Tabelas | 5 em `app`, todas com RLS |
| Dados permanentes do teste | 0; transação revertida |
| Leitura cross-tenant | Negada |
| Escrita cross-tenant | Negada |
| Função pública privilegiada | Sem `EXECUTE` para `anon` e `authenticated` |
| Advisor de segurança | 0 alertas |
| Advisor de performance | 2 informações de índices ainda não usados; esperado em banco vazio |

## Estado dos ambientes

| Ambiente | Estado | Observação |
|---|---|---|
| DEV | Migrado e testado para o escopo base | Região `ca-central-1` |
| PROD | Vazio e sem migrations | Região `us-west-2`; não foi alterado |
| Configurador Sites | Protótipo público, versão 10 | 0 variáveis de runtime; sem conexão com backend/Supabase |
| WhatsApp, Google e OpenAI | `MOCK` | Nenhum evento real conectado |

O Sites está em acesso público e sem variáveis de runtime configuradas. Deve permanecer rotulado como\nprotótipo e não receber dados reais enquanto autenticação, backend e políticas não estiverem conectados.\n\nA região dos dois projetos diverge da decisão anterior de usar São Paulo. Isso não invalida o teste
técnico da FV-01, mas deve ser decidido antes de clientes reais por latência, residência de dados,
custo e eventual migração.

## Matriz de QA

| Critério | Estado | Evidência/limite |
|---|---|---|
| Visível | Parcial | Site protótipo existe; aplicação do monorepo ainda é mínima |
| Editável | Não iniciado | Configurador persistente ainda não implementado |
| Persistente | Parcial | Schema remoto persiste; CRUD de configuração não existe |
| Aplicado ao motor | Parcial | Compilador inicial possui 7 testes unitários |
| Erro tratado | Parcial | RLS nega cross-tenant; fluxos de aplicação ainda incompletos |
| Testado | Parcial | Smoke RLS aprovado; Gate A ainda exige 20 cenários |
| Rotulado | Aprovado | Integrações seguem declaradas como `MOCK` |

## Avaliação do WhatsApp MCP externo

O upstream foi classificado como **referência técnica somente**. Ele usa WhatsApp Web pessoal,
QR code, Go/Python/SQLite e alerta para risco de banimento e exfiltração. Incorporá-lo ao runtime
violaria RF-WHA-001 e BT-500. O SaaS continuará com a WhatsApp Cloud API oficial na FV-06.

## Pendências do Gate A

- Autenticação e resolução server-side do tenant.
- Entidades de configuração, rascunho, publicação e hash.
- CRUD real no backend e configurador.
- Motor completo da FV-01 e endpoint autorizado de simulação.
- Execução dos 20 cenários obrigatórios.
- Backup externo real criptografado e teste de restauração.
- CI remoto e relatório final de QA/Segurança.

## Pergunta que bloqueia o próximo passo

Nenhuma para continuar a implementação técnica da FV-01. A região precisa de decisão antes do
piloto com clientes reais, não antes da próxima fatia de código.
