# FV-05 — OpenAI checkpoint 001: credencial real e edge autenticada no DEV

**Data:** 04 de agosto de 2026  
**Ambiente:** Supabase DEV São Paulo  
**Estado:** `IN_PROGRESS` — provedor real validado; E2E autenticado por tenant pendente

## Entregue

- chave criada no projeto OpenAI correto por fluxo criptografado;
- chamada mínima real concluída com `gpt-5.6-sol`;
- segredo `OPENAI_API_KEY` armazenado somente no cofre remoto do Supabase DEV;
- cópia local removida após confirmação do digest remoto;
- modelo e origem permitida configurados no ambiente remoto;
- função `interpret-booking-intent` publicada e ativa no Supabase DEV;
- saída estruturada por JSON Schema;
- `store=false` e `safety_identifier` pseudonimizado;
- mensagem do cliente não é escrita nos logs comuns;
- guard de tenant executa com privilégios do usuário e RLS;
- chamada sem sessão comprovadamente recusada com HTTP 401;
- Supabase Security Advisor novamente com zero lints.

## Limite de decisão da IA

A função somente extrai:

- intenção;
- serviço mencionado;
- data e período preferidos;
- nome informado;
- necessidade e campos de esclarecimento.

A IA não calcula disponibilidade, duração, preço, equipe, recursos, política, hold ou confirmação. Essas decisões continuam reservadas ao motor determinístico e à configuração publicada.

## Evidências

| Evidência                                | Resultado                                     |
| ---------------------------------------- | --------------------------------------------- |
| OpenAI Responses API real                | `OPENAI_API_OK`                               |
| Modelo resolvido em documentação oficial | `gpt-5.6-sol`                                 |
| Função remota                            | versão 1, `ACTIVE`                            |
| Requisição sem autenticação              | `UNAUTHENTICATED_REQUEST_BLOCKED_401`         |
| Edge log                                 | POST 401 registrado, sem conteúdo da mensagem |
| Security Advisor após hardening          | zero lints                                    |

## O que falta para `SANDBOX_CONNECTED`

1. criar ou convidar o primeiro usuário administrador no Supabase Auth;
2. associá-lo por membership ao tenant de teste;
3. obter sessão real pelo fluxo do configurador;
4. executar uma mensagem de agendamento autorizada;
5. comprovar saída estruturada e bloqueio cross-tenant;
6. incorporar o resultado ao orquestrador sem permitir confirmação pela IA.

Nenhuma promoção ao PROD ocorreu neste checkpoint. PROD receberá uma chave própria e somente depois do E2E do DEV.
