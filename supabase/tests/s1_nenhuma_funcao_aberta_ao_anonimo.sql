-- S1: nenhuma função SECURITY DEFINER pode ser chamada pelo papel anônimo.
--
-- O papel `anon` é a chave pública que vai dentro do JavaScript do site. Uma
-- função SECURITY DEFINER alcançável por ele é uma função que qualquer pessoa
-- na internet pode executar com os poderes do dono do banco.
--
-- Este teste existe porque o defeito já aconteceu: 33 funções nasceram assim,
-- uma de cada vez, porque `create function` concede EXECUTE a PUBLIC por padrão
-- e ninguém escreveu o `revoke`. O guardrail em `scripts/guardrails.mjs` pega no
-- código; este pega no banco de verdade, que é onde a permissão realmente mora.

begin;

do $$
declare
  v_abertas text;
  v_para_logado text;
begin
  select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname, p.proname)
    into v_abertas
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.prosecdef
     and n.nspname in ('public', 'app', 'api')
     and has_function_privilege('anon', p.oid, 'EXECUTE');

  if v_abertas is not null then
    raise exception 'Funcoes SECURITY DEFINER abertas ao papel anon: %', v_abertas;
  end if;

  -- Quem está logado alcança um punhado, e cada uma delas precisa autorizar
  -- pela sessão (auth.uid() / auth.jwt()), nunca por parâmetro do chamador.
  -- Uma função nova aparecendo aqui é uma decisão, não um acidente: ou ela
  -- confere a sessão, ou ela não deveria estar nesta lista.
  select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname, p.proname)
    into v_para_logado
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.prosecdef
     and n.nspname in ('public', 'app', 'api')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');

  if coalesce(v_para_logado, '') <> 'api.check_configuration_readiness, api.publish_configuration, '
                                  || 'app.storage_folder_is_my_tenant, public.complete_owner_signup' then
    raise exception 'A lista de funcoes chamaveis por usuario logado mudou: %', coalesce(v_para_logado, '(nenhuma)');
  end if;
end $$;

select 'S1 OK: nenhuma funcao SECURITY DEFINER aberta ao anonimo' as resultado;

rollback;
