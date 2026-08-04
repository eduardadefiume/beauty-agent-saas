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
