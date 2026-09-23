# Remote database tests

These tests run only against the dedicated Supabase DEV project for this SaaS. They must never
target another product, PROD, or start a local database.

## FV-01

- `fv01_rls_smoke.sql` validates positive tenancy access, denies cross-tenant read/write and
  checks hardened public-function privileges.
- `fv01_configuration_smoke.sql` validates composite tenant constraints, RLS on the configuration
  catalog and published-version immutability.
- `fv01_publish_smoke.sql` builds a complete configuration, checks readiness, publishes an atomic
  snapshot and proves that the active version and its source cannot be mutated.

Every test creates transaction-scoped users and fixtures and ends with `ROLLBACK`. Evidence from
04 August 2026 is recorded in `docs/status/fv-01-checkpoint-005.md`. Rerun the suite after every
policy, grant, readiness or publishing change.

## S10 — o lembrete de véspera

- `s10_o_lembrete_so_sai_na_vespera.sql` prova os quatro desfechos do agendador
  (envia na véspera, pula no mesmo dia, espera quando falta mais de um dia,
  pula sem modelo registrado), confere o que foi parar na fila e prova a
  idempotência de uma segunda rodada.

Diferente dos anteriores, ele **monta o salão inteiro do zero** em vez de
depender de uma conexão já existente — o DEV sobe vazio, e teste que só roda em
banco povoado não roda quando mais importa. Ele também escolhe um fuso
`Etc/GMT*` onde agora seja meio-dia, porque o agendador só envia entre 8h e
21h locais: com fuso fixo o teste passaria de dia e falharia de madrugada.

Na primeira execução ele encontrou um defeito que nenhuma leitura de código
teria achado: `check (template_name ~ '^[a-z0-9_]{1,512}$')` é aceito pelo
`create table` e só estoura no primeiro insert, porque o Postgres recusa
repetição acima de 255. Corrigido na migration 20260923204500.
