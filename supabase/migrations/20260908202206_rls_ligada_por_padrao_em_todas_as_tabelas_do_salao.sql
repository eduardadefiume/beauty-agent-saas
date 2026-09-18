-- RLS LIGADA POR PADRAO, MESMO ONDE HOJE NAO FAZ FALTA
--
-- Vinte e nove tabelas estavam sem RLS. Hoje isso NAO e exposicao: o papel
-- `anon` nao tem USAGE no schema `app`, e nenhuma dessas tabelas concede
-- privilegio a `anon` ou a `authenticated`. Elas so sao alcancadas por
-- `service_role`, que e quem as Edge Functions usam.
--
-- Entao por que mexer? Porque a seguranca delas depende INTEIRAMENTE de
-- ninguem nunca escrever um `grant`. E este projeto acabou de provar que
-- esquece exatamente esse tipo de linha -- 33 vezes seguidas, no caso das
-- funcoes SECURITY DEFINER.
--
-- Com RLS ligada e nenhuma politica, a tabela nega tudo para quem nao tem
-- BYPASSRLS. Um `grant select ... to authenticated` escrito por distracao passa
-- a ser inofensivo em vez de abrir a tabela inteira. E a diferenca entre um
-- erro que vira incidente e um erro que vira nada.
--
-- POR QUE NAO QUEBRA: `service_role` e `postgres` tem rolbypassrls = true.
-- As Edge Functions usam service_role; as funcoes SECURITY DEFINER rodam como
-- o dono. Nenhum dos dois enxerga a politica.
--
-- POR QUE SEM POLITICA: escrever politica para tabela que ninguem alcanca
-- seria inventar regra sem caso de uso, e regra inventada envelhece errado.
-- Quando uma dessas tabelas precisar ser lida direto pelo navegador, a politica
-- nasce junto com o `grant` -- e o guardrail cobra as duas coisas.

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