# FV-01 — checkpoint 001

**Data:** 03 de agosto de 2026  
**Estado:** `IN_PROGRESS`  
**Rótulo:** protótipo funcional local da aplicação; integrações externas `MOCK`; banco remoto ainda não conectado

## Resultado entregue

- Monorepo `pnpm`/Turborepo com `web`, `api`, `worker` e sete pacotes internos.
- Versões exatas e lockfile versionado.
- Contratos base para UUIDs, datas com offset, fuso IANA, erros, paginação e correlação.
- Relógio, IDs e interface de log injetáveis.
- Primeiro compilador puro de serviços simples e compostos.
- Pausa capaz de liberar pessoa e manter recurso ocupado no plano relativo.
- Migration base para schemas `app`/`private`, tenancy, memberships, auditoria e RLS.
- Guardrail automatizado contra segredo versionado e regra condicionada por `William` ou `Jack`.
- API NestJS compilada e endpoint `GET /health` executado com resposta `MOCK` explícita.

## Evidência executada

| Verificação                    | Resultado                                        |
| ------------------------------ | ------------------------------------------------ |
| Guardrails de nomes e segredos | Aprovado                                         |
| ESLint                         | 10/10 workspaces aprovados                       |
| TypeScript estrito             | 10/10 workspaces aprovados                       |
| Testes unitários               | 7 aprovados, 0 reprovados                        |
| Builds independentes           | 10/10 aprovados                                  |
| Formatação                     | Aprovada                                         |
| Endpoint de saúde compilado    | HTTP 200 com `phase=FV-01` e `integrations=MOCK` |

## Matriz de QA deste checkpoint

| Critério          | Estado       | Evidência/limite                                                            |
| ----------------- | ------------ | --------------------------------------------------------------------------- |
| Visível           | Parcial      | Página inicial mínima e health endpoint existem.                            |
| Editável          | Não iniciado | Configurador ainda não foi implementado.                                    |
| Persistente       | Não iniciado | Migration não foi aplicada no Supabase remoto.                              |
| Aplicado ao motor | Parcial      | Serviços simples/compostos e pausa estão cobertos por teste puro.           |
| Erro tratado      | Parcial      | Sequência duplicada, duração inválida e serviço sem etapas possuem códigos. |
| Testado           | Parcial      | Sete testes unitários; Gate A exige vinte cenários e testes remotos de RLS. |
| Rotulado          | Aprovado     | Aplicação declara `MOCK`; relatório não chama FV-01 de concluída.           |

## Auditoria de Segurança

| Item                          | Estado                    | Motivo                                          |
| ----------------------------- | ------------------------- | ----------------------------------------------- |
| Segredo no repositório        | Aprovado neste checkpoint | Scan automatizado não encontrou chave ou token. |
| Regra por nome de piloto      | Aprovado neste checkpoint | Domínio e motor não contêm William ou Jack.     |
| Motor isolado de SDK/rede     | Aprovado neste checkpoint | Pacote não possui dependências externas.        |
| RLS e isolamento cross-tenant | Bloqueado                 | Exige o novo projeto Supabase remoto exclusivo. |
| Grants e advisors Supabase    | Bloqueado                 | Migration ainda não foi aplicada.               |

## Estado dos itens iniciados

| Item   | Estado real                                                      |
| ------ | ---------------------------------------------------------------- |
| BT-001 | `IN_REVIEW`                                                      |
| BT-002 | `IN_PROGRESS` — falta CI remoto                                  |
| BT-003 | `IN_PROGRESS` — falta OpenAPI                                    |
| BT-004 | `IN_PROGRESS` — primitivos e testes iniciais implementados       |
| BT-005 | `IN_PROGRESS` — falta validação completa de ambientes            |
| BT-010 | `IN_PROGRESS` — migration não executada remotamente              |
| BT-011 | `IN_PROGRESS` — estrutura escrita, não validada no banco         |
| BT-012 | `IN_PROGRESS` — policies escritas, suíte cross-tenant bloqueada  |
| BT-040 | `IN_PROGRESS` — compilador relativo inicial implementado         |
| BT-043 | `IN_PROGRESS` — sem alocação concorrente ainda                   |
| BT-050 | `IN_PROGRESS` — guardrail existe; fixtures definitivas ainda não |

## Bloqueio externo

Criar e vincular um projeto Supabase remoto exclusivo do SaaS. Não usar os projetos
`refeitorio` e não executar banco local. A fundadora precisa decidir entre nova organização no
login atual ou nova conta com outro e-mail antes da criação do ambiente.
