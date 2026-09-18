# Migrations escritas e revisadas, ainda NAO aplicadas

Esta pasta existe para nao quebrar a regra que vale desde 18/09/2026:
`supabase/migrations/` e um espelho exato do que o banco aplicou, na ordem em
que aplicou. Arquivo que ainda nao foi aplicado nao pode morar la.

## Fluxo

1. A migration nasce aqui, com nome sem timestamp.
2. Quando for aplicada no banco, o Supabase atribui a versao real.
3. Ai o arquivo se move para `supabase/migrations/<versao>_<nome>.sql`,
   e se confere o md5 contra `supabase_migrations.schema_migrations`.

Enquanto estiver aqui, a migration NAO esta no ar.
