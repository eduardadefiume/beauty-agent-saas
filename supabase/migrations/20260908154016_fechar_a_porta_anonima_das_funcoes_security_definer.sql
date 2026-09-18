-- FECHAR A PORTA ANÔNIMA DAS FUNÇÕES SECURITY DEFINER
--
-- No PostgreSQL, `create function` concede EXECUTE ao papel PUBLIC por padrão.
-- O papel `anon` -- a chave pública que vai embutida no JavaScript do site --
-- herda de PUBLIC. Então escrever `grant execute ... to service_role` no fim da
-- migração não restringe coisa alguma: é uma concessão a mais em cima de uma
-- porta que já estava aberta.
--
-- Trinta e três funções SECURITY DEFINER estavam nesse estado. Elas autorizam
-- comparando parâmetros que o próprio chamador envia (`require_site_tenant`),
-- o que é aceitável enquanto só o `service_role` alcança a função -- porque aí
-- quem confere a identidade de verdade é a Edge Function, lendo o JWT. Sem a
-- porta fechada, esse raciocínio desaba: qualquer pessoa com a trinca
-- (site_project_id, email, tenant_id) entrava, e a trinca não é segredo -- o
-- tenant_id aparece na URL do painel e o e-mail é o do login.
--
-- Entre as expostas estavam: leitura do arquivo de conversas importadas,
-- reescrita das regras do agente, `site_forget_contact_history` (destrutiva) e
-- `app.enqueue_outbound_message`, que enfileira mensagem no número do salão.
--
-- A ORDEM IMPORTA. Revogar de PUBLIC sem antes conceder ao `service_role`
-- derrubaria as funções de `app.*`, que não têm ACL própria nenhuma e hoje
-- alcançam o banco exatamente por herdar PUBLIC.
--
-- O QUE NÃO MUDA: o corpo das funções. O defeito nunca esteve no que elas
-- fazem, e sim na falta de uma linha dizendo quem pode chamá-las.

do $ajuste$
declare
  r record;
  v_fechadas integer := 0;
begin
  for r in
    select p.oid, n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.prosecdef
       and n.nspname in ('public', 'app', 'api')
       and has_function_privilege('anon', p.oid, 'EXECUTE')
       -- O predicado das políticas de storage é a exceção, tratada abaixo.
       and not (n.nspname = 'app' and p.proname = 'storage_folder_is_my_tenant')
  loop
    execute format('grant execute on function %I.%I(%s) to service_role',
                   r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from public, anon, authenticated',
                   r.nspname, r.proname, r.args);
    v_fechadas := v_fechadas + 1;
  end loop;

  raise notice 'Funcoes fechadas: %', v_fechadas;
end
$ajuste$;

-- A EXCEÇÃO, E ELA É O MODELO DO QUE AS OUTRAS DEVERIAM SER.
--
-- `storage_folder_is_my_tenant` é chamada pelas 11 políticas de RLS do storage,
-- que rodam com o papel de quem está enviando o arquivo -- `authenticated`.
-- Tirar o acesso dela quebraria todo upload de foto do salão.
--
-- E ela PODE continuar aberta porque não aceita identidade por parâmetro: lê
-- `auth.jwt() ->> 'email'` da sessão. É a diferença entre "quem você diz que é"
-- e "quem o banco sabe que você é" -- e é o mesmo caminho que
-- `private.has_tenant_role` já usa com `auth.uid()`.
grant execute on function app.storage_folder_is_my_tenant(text) to authenticated, service_role;
revoke all on function app.storage_folder_is_my_tenant(text) from public, anon;
