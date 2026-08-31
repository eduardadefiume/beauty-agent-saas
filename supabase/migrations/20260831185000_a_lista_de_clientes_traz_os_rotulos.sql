-- A ficha guarda comprimento e volume como id de opcao (app.knowledge_options).
-- A leitura da lista nao trazia os rotulos, entao uma tela de Clientes so teria
-- um UUID para mostrar -- e nenhuma forma de oferecer as opcoes para escolher.
-- Sem isso, "CLASSIFICACAO" fica na lista de pendencias da cliente e nao existe
-- lugar nenhum para resolver.
--
-- A lista passa a vir junto, numa chave nova ao lado de 'clients'. Chave nova
-- em vez de mudar o formato: quem ja le 'clients' continua lendo igual.
do $$
declare
  antes  constant text := $t$    ), '[]'::jsonb)
  );
end;$t$;
  depois constant text := $t$    ), '[]'::jsonb),
    'classificationOptions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dimension', d.name,
               'optionId',  o.id,
               'label',     o.label
             ) order by d.position, o.position, o.label)
        from app.knowledge_options o
        join app.knowledge_dimensions d on d.id = o.dimension_id
       where o.tenant_id = target_tenant_id
         and o.status = 'ACTIVE'
         and d.status = 'ACTIVE'
    ), '[]'::jsonb)
  );
end;$t$;
  definicao text;
begin
  select pg_get_functiondef(p.oid)
    into definicao
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'site_load_clients';

  if definicao is null then
    raise exception 'public.site_load_clients nao existe';
  end if;

  if position('classificationOptions' in definicao) > 0 then
    raise notice 'a lista ja traz os rotulos, nada a fazer';
    return;
  end if;

  if position(antes in definicao) = 0 then
    raise exception 'o fim de site_load_clients nao esta como esperado; nada foi alterado';
  end if;

  execute replace(definicao, antes, depois);
end $$;
