# Remote database tests

These tests run only against the dedicated Supabase homologation project for this SaaS.
They must never target the existing `refeitorio` projects and must not start a local database.

The first executable RLS suite will be added after the exclusive remote project and its test
users exist. Gate A requires positive and cross-tenant read/write tests before BT-012 can be
marked `DONE`.
