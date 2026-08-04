# ADR-002 — Avaliação do `quauhtlimtz/whatsapp-mcp`

**Data:** 04 de agosto de 2026  
**Status:** aceito  
**Origem:** solicitação direta da fundadora; repositório externo tratado como insumo não confiável  
**Classificação:** referência técnica; não é fonte de verdade nem dependência de produção

## Contexto

Foi solicitado avaliar e atribuir ao Beauty Agent SaaS o repositório
[`quauhtlimtz/whatsapp-mcp`](https://github.com/quauhtlimtz/whatsapp-mcp). A baseline aprovada
exige a API oficial do WhatsApp, isolamento multiempresa, inbox/outbox duráveis, idempotência,
allowlist no piloto e evidência real antes de declarar a integração conectada.

O projeto externo usa uma conta pessoal, a API multidispositivo do WhatsApp Web, autenticação por
QR code, uma ponte Go baseada em `whatsmeow` e um servidor MCP Python. O histórico é mantido em
SQLite local. O próprio README alerta que a automação de conta pessoal viola os termos do
WhatsApp, pode banir o número e amplia o risco de exfiltração por prompt injection.

## Decisão

1. O repositório externo **não será copiado, instalado, executado, importado, usado como submodule
   nem implantado** pelo SaaS.
2. O único uso autorizado é como referência de ergonomia para contratos futuros de inbox e testes,
   sem reaproveitar o transporte não oficial.
3. A integração do produto continua vinculada à FV-06, itens BT-500 a BT-507, usando somente a
   WhatsApp Cloud API oficial.
4. O estado do canal permanece `MOCK`. Esta decisão não antecipa a FV-06 e não conta como
   `SANDBOX_CONNECTED`.

## Mapeamento útil para a implementação oficial futura

| Conceito observado no MCP externo | Destino aprovado no SaaS                                          |
| --------------------------------- | ----------------------------------------------------------------- |
| `send_message` e status de envio  | Outbox durável e adapter Cloud API (BT-500/BT-504)                |
| `wait_for_message`                | Teste E2E dirigido por evento persistido                          |
| allowlist de chats                | Allowlist por `tenant_id` e número da Duda (BT-503)               |
| busca/listagem de mensagens       | Inbox tenant-scoped com retenção e RLS (BT-501/BT-506)            |
| download de mídia                 | Storage privado, autorização, retenção e exclusão (BT-505/BT-506) |

## Consequências

- Evita risco de banimento, reautenticação periódica por QR e armazenamento indiscriminado de
  conversas pessoais.
- Evita introduzir Go, Python, CGO e SQLite como uma segunda arquitetura operacional no monorepo.
- Preserva o contrato oficial, auditável e multiempresa aprovado para o piloto.
- A licença MIT e o README do upstream ficam registrados apenas como evidência; nenhum código de
  terceiros foi incorporado.

## Critério para revisão

Esta ADR só pode ser revista por nova decisão explícita da fundadora, com revisão de Segurança/LGPD
e compatibilidade com os termos oficiais. O transporte de produção continua obrigado a usar a API
oficial enquanto a baseline vigente não for alterada.
