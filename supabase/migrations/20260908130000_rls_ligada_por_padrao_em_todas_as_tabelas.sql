-- RLS LIGADA POR PADRÃO, MESMO ONDE HOJE NÃO FAZ FALTA
--
-- Vinte e nove tabelas estavam sem RLS. Antes de mexer eu medi o que isso
-- significava de verdade, e o resultado contraria o susto: **hoje não é
-- exposição**. O papel `anon` não tem USAGE no schema `app`, e nenhuma dessas
-- tabelas concede privilégio a `anon` ou a `authenticated`. Elas só são
-- alcançadas por `service_role`, que é quem as Edge Functions usam.
--
-- (As 34 tabelas que o usuário logado realmente alcança já tinham RLS e
-- política isolando por salão. As únicas 4 políticas com `using (true)` são
-- `TO service_role`, o que é inofensivo.)
--
-- Então por que mexer? Porque a segurança dessas 29 depende INTEIRAMENTE de
-- ninguém nunca escrever um `grant`. E este projeto acabou de provar que
-- esquece exatamente esse tipo de linha -- 33 vezes seguidas, no caso das
-- funções SECURITY DEFINER. Sete destas tabelas são minhas, criadas nas últimas
-- semanas, e eu não liguei RLS em nenhuma.
--
-- Com RLS ligada e nenhuma política, a tabela nega tudo para quem não tem
-- BYPASSRLS. Um `grant select ... to authenticated` escrito por distração passa
-- a ser inofensivo em vez de abrir a tabela inteira. É a diferença entre um erro
-- que vira incidente e um erro que vira nada.
--
-- POR QUE NÃO QUEBRA: `service_role` e `postgres` têm rolbypassrls = true. As
-- Edge Functions usam service_role; as funções SECURITY DEFINER rodam como o
-- dono. Nenhum dos dois enxerga a política. Conferido depois de aplicar:
-- `agent_prompt()` e `build_agent_context()` continuam carregando.
--
-- POR QUE SEM POLÍTICA: escrever política para tabela que ninguém alcança seria
-- inventar regra sem caso de uso, e regra inventada envelhece errado. Quando uma
-- destas tabelas precisar ser lida direto pelo navegador, a política nasce junto
-- com o `grant` -- e o guardrail cobra as duas coisas.

do $ligar$
declare
  r record;
  v_ligadas integer := 0;
begin
  for r in
    select c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app' and c.relkind = 'r' and not c.relrowsecurity
     order by c.relname
  loop
    execute format('alter table app.%I enable row level security', r.relname);
    v_ligadas := v_ligadas + 1;
  end loop;

  raise notice 'RLS ligada em % tabelas', v_ligadas;
end
$ligar$;
