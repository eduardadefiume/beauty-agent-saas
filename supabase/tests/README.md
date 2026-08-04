# Remote database tests

These tests run only against the dedicated Supabase DEV project for this SaaS. They must never
target another product, PROD, or start a local database.

## FV-01

`fv01_rls_smoke.sql` creates transaction-scoped users and tenants, validates positive access,
denies cross-tenant read/write, checks that the public automatic-RLS function is not executable by
API roles, and rolls all test data back.

Evidence from 04 August 2026 is recorded in
`docs/status/fv-01-checkpoint-003.md`. The file must be rerun after every policy or grant change.
