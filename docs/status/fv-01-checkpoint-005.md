# FV-01 — Checkpoint 005: núcleo configurável e publicação no DEV

**Data:** 04 de agosto de 2026  
**Branch:** `feature/fv01-checkpoint-002`  
**Ambiente validado:** Supabase DEV São Paulo (`hjghwryhphgusefyivbl`)  
**Estado das integrações:** `MOCK`

## Resultado deste checkpoint

O banco do DEV agora representa, por tenant e por rascunho:

- expediente semanal e limite diário de término;
- equipe, modo de disponibilidade, faixas fixas e habilidades;
- tipos de recurso, recursos e capacidade;
- serviços simples ou compostos, variações e etapas ordenadas;
- requisitos de habilidade e recurso por etapa;
- liberação de pessoa em etapa passiva e retenção de recurso;
- rascunho com revisão otimista;
- versão publicada imutável, snapshot determinístico, hash SHA-256 e ponteiro ativo por unidade.

A política do piloto está materializada no banco: `deposit_enabled=false` e canal em modo `RESTRICTED`. Sinal e pagamento não são dependências da primeira fase.

## Segurança e integridade

- todas as novas tabelas possuem `tenant_id NOT NULL`;
- relações entre entidades usam chaves compostas para impedir vínculo entre tenants;
- RLS foi habilitado em todas as tabelas novas;
- escrita administrativa exige papel `OWNER` ou `ADMIN`;
- filhos de rascunho fechado não podem ser alterados;
- versões publicadas não possuem privilégio de atualização e também têm trigger de imutabilidade;
- funções internas permanecem fora do acesso de `anon` e `authenticated`;
- Supabase Security Advisor: zero lints após as migrations;
- chaves estrangeiras sinalizadas pelo linter receberam índices.

## Prontidão e publicação

`api.check_configuration_readiness` devolve códigos estáveis para:

- `UNIT_TIMEZONE_MISSING`;
- `OPERATING_HOURS_MISSING`;
- `LATEST_END_MISSING`;
- `NO_ACTIVE_MEMBER`;
- `MEMBER_AVAILABILITY_INVALID`;
- `NO_BOOKABLE_SERVICE`;
- `SERVICE_HAS_NO_STEPS`;
- `STEP_HAS_NO_QUALIFIED_MEMBER`;
- `RESOURCE_CAPACITY_MISSING`;
- `FINAL_MESSAGE_MISSING`.

`api.publish_configuration`:

1. bloqueia revisão divergente;
2. bloqueia rascunho incompleto;
3. trava rascunho e unidade na transação;
4. monta snapshot com ordenação determinística;
5. calcula hash SHA-256;
6. cria a próxima versão;
7. fecha o rascunho;
8. troca o ponteiro ativo da unidade;
9. grava auditoria com `correlation_id`.

## Evidências executadas no DEV

| Evidência                                | Resultado                                                                              |
| ---------------------------------------- | -------------------------------------------------------------------------------------- |
| Isolamento e integridade da configuração | `CONFIGURATION_SMOKE_OK`                                                               |
| Prontidão e publicação atômica           | `PUBLISH_SMOKE_OK`                                                                     |
| Security Advisor                         | zero lints                                                                             |
| Performance Advisor                      | sem chaves estrangeiras não indexadas; somente índices ainda não usados no banco vazio |

Os testes usam transação com `ROLLBACK`; nenhum tenant, usuário ou dado de agenda de teste foi mantido.

## Estado honesto do Gate A

| Área                          | Estado     | Observação                                                               |
| ----------------------------- | ---------- | ------------------------------------------------------------------------ |
| Fundação, contratos e tenancy | parcial    | base versionada; autenticação/seleção de tenant ainda sem fluxo completo |
| Modelo configurável           | em revisão | núcleo do banco e integridade concluídos no DEV                          |
| Prontidão e publicação        | em revisão | funções e testes de banco concluídos no DEV                              |
| Painel configurador           | backlog    | site publicado ainda é protótipo                                         |
| Motor completo e simulador    | backlog    | compilador cobre somente linha do tempo relativa                         |
| Hold, concorrência e agenda   | backlog    | não pertencem a este checkpoint                                          |
| Google Calendar               | `MOCK`     | conexão real proibida antes dos gates anteriores                         |
| OpenAI                        | `MOCK`     | não participa de disponibilidade, duração, preço ou confirmação          |
| WhatsApp                      | `MOCK`     | conexão real restrita ao número da Duda e posterior ao simulador         |
| Sinal/pagamento               | suspenso   | explicitamente fora da primeira fase                                     |

## Promoção

Estas migrations foram aplicadas apenas no DEV. O PROD permanece sem esta expansão até:

1. contratos e comandos de aplicação estarem cobertos;
2. interface mínima persistir e recarregar os módulos;
3. cenários do Gate A passarem;
4. evidências de regressão e rollback estarem registradas.

## Próxima fatia

Implementar os contratos e comandos do configurador, a tela modular e os testes de persistência; em seguida completar motor determinístico e simulador antes de qualquer conexão real de agenda ou WhatsApp.
