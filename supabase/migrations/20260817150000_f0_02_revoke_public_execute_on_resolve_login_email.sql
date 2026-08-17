-- F0-02: fecha o ultimo RPC SECURITY DEFINER alcancavel sem autenticacao.
--
-- public.resolve_login_email(cpf) converte um CPF no e-mail de login da pessoa.
-- Enquanto alcancavel pelo papel anon, funcionava como oraculo de CPF para
-- e-mail: chamavel direto no PostgREST com a chave publicavel, sem sessao e sem
-- limite de tentativas. Alem do vazamento em si, era a peca que permitia montar
-- a trinca (site_project_id, email, tenant_id) exigida por
-- private.require_site_tenant e usada pelas RPCs fechadas em F0-01/F0-01b.
--
-- Precondicao satisfeita antes de aplicar: as rotas /api/auth/login e
-- /api/auth/signup passaram a chamar esta funcao com a chave secreta, via
-- apps/web/lib/supabase/admin-rpc.ts. O deploy foi confirmado em producao pelo
-- teste de entrar no sistema com CPF e senha, que so funciona pelo caminho da
-- chave secreta (o helper nao tem fallback para a chave publicavel).
--
-- Revoga de PUBLIC alem dos papeis nominais: CREATE FUNCTION concede EXECUTE a
-- PUBLIC por padrao, e anon/authenticated herdam desse grant. Foi exatamente o
-- que fez a primeira tentativa de F0-01 nao surtir efeito.
--
-- Resultado verificado apos aplicar:
--   resolve_login_email -> anon=false, authenticated=false, service_role=true
--   ACL = "postgres=X/postgres | service_role=X/postgres" (sem PUBLIC)
--   Total de funcoes em public alcancaveis por anon: 0

revoke execute on function public.resolve_login_email(target_cpf_digits text) from public;
revoke execute on function public.resolve_login_email(target_cpf_digits text) from anon, authenticated;
