# FV-01 — Checkpoint 004: migração regional e publicação

Data: 2026-08-04  
Branch: `feature/fv01-checkpoint-002`

## Resultado

Os ambientes Supabase DEV e PROD foram recriados na região específica
`sa-east-1` (South America — São Paulo). Os projetos anteriores foram
pausados e permanecem recuperáveis durante a janela de validação.

| Ambiente | Projeto ativo | Região | Projeto anterior |
| --- | --- | --- | --- |
| DEV | `agente-beleza-saas-dev-sp` (`hjghwryhphgusefyivbl`) | `sa-east-1` | `mhlnhtvvleprnamxrsoi`, pausado em `ca-central-1` |
| PROD | `agente-beleza-saas-prod-sp` (`dboygmtrzgsfcmoquegp`) | `sa-east-1` | `vwtqgukockqaiptdqwtt`, pausado em `us-west-2` |

A organização permanece no plano Free. A criação dos projetos teve custo
confirmado de US$ 0/mês por projeto.

## Migrações aplicadas

Nos dois ambientes ativos:

1. `fv01_base_tenancy`;
2. `harden_default_privileges`.

A migração de hardening e o smoke test foram ajustados para funcionar tanto em
projetos que possuem `public.rls_auto_enable()` quanto em projetos novos onde
essa função não existe.

## Evidências

- cinco tabelas de negócio criadas no schema `app`;
- RLS habilitado nas cinco tabelas;
- zero usuários, tenants, unidades, memberships, logs e objetos de Storage;
- teste transacional `RLS_SMOKE_OK` aprovado em DEV e PROD;
- leitura e escrita cross-tenant negadas;
- zero lints de segurança nos advisors de DEV e PROD;
- dois avisos informativos de índices ainda não usados, esperados em bancos
  vazios;
- nenhuma chave administrativa exposta.

## Publicação

O site público recebeu as variáveis `SUPABASE_URL` e
`SUPABASE_PUBLISHABLE_KEY` do novo PROD. A versão 10 foi republicada com a
revisão de ambiente 1 e respondeu `HTTP 200 OK` em:

<https://configurador-agentes-beleza.eddigital-oficial.chatgpt.site>

## Rollback

Enquanto os projetos anteriores estiverem pausados, o rollback consiste em
restaurar o projeto correspondente e reverter as variáveis do ambiente
publicado. Nenhum projeto anterior foi excluído.
