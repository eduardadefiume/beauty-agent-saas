-- O QUE MUDA AO PUBLICAR.
--
-- 28/09/2026, teste com dono-robo: ele disse "o penteado agora e 280" (sem
-- publicar) e depois "fioterapia agora 290, publica". O Eddy publicou os dois
-- e so contou a fioterapia: o penteado foi ao ar sem o dono saber. O resumo
-- que o Eddy le traz o rascunho inteiro, nao a diferenca -- ele nao tinha
-- como ver. Aqui a diferenca, item por item, entre o rascunho e a versao no
-- ar. O Eddy conta isso antes de publicar e a trava do codigo confere.

create or replace function app.eddy_o_que_muda_ao_publicar(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_rascunho uuid;
  v_snap     jsonb;
  v_itens    jsonb := '[]'::jsonb;
begin
  select d.id into v_rascunho
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
   order by d.revision desc limit 1;

  select v.snapshot into v_snap
    from app.configuration_versions v
   where v.tenant_id = p_tenant_id
   order by v.version_number desc limit 1;

  if v_rascunho is not null then
    with agora as (
      select s.name,
             s.status::text = 'ACTIVE' as ativo,
             s.base_price_minor as preco,
             s.price_is_floor as piso,
             (select coalesce(sum(st.duration_minutes), 0) from app.service_steps st where st.service_id = s.id) as total,
             (select coalesce(sum(st.duration_minutes), 0) from app.service_steps st where st.service_id = s.id and st.kind = 'PASSIVE') as pausa,
             (select coalesce(string_agg(v.name || ' R$' || (v.price_minor / 100)::text, ', ' order by v.name), '')
                from app.service_variations v where v.service_id = s.id and v.status = 'ACTIVE') as variacoes
        from app.services s
       where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_rascunho
    ),
    antes as (
      select x->>'name' as name,
             x->>'status' = 'ACTIVE' as ativo,
             (x->>'base_price_minor')::integer as preco,
             coalesce((x->>'price_is_floor')::boolean, false) as piso,
             (select coalesce(sum((st->>'duration_minutes')::integer), 0) from jsonb_array_elements(coalesce(x->'steps', '[]'::jsonb)) st) as total,
             (select coalesce(sum((st->>'duration_minutes')::integer), 0) from jsonb_array_elements(coalesce(x->'steps', '[]'::jsonb)) st where st->>'kind' = 'PASSIVE') as pausa,
             (select coalesce(string_agg((vv->>'name') || ' R$' || ((vv->>'price_minor')::integer / 100)::text, ', ' order by vv->>'name'), '')
                from jsonb_array_elements(coalesce(x->'variations', '[]'::jsonb)) vv where coalesce(vv->>'status', 'ACTIVE') = 'ACTIVE') as variacoes
        from jsonb_array_elements(coalesce(v_snap->'services', '[]'::jsonb)) x
    ),
    par as (
      select coalesce(a.name, b.name) as nome, a.ativo as a_ativo, b.ativo as b_ativo,
             a.preco as a_preco, b.preco as b_preco, a.piso as a_piso, b.piso as b_piso,
             a.total as a_total, b.total as b_total, a.pausa as a_pausa, b.pausa as b_pausa,
             a.variacoes as a_var, b.variacoes as b_var
        from agora a full join antes b on lower(a.name) = lower(b.name)
    ),
    mudancas as (
      select nome, 'entra no catálogo (R$ ' || (a_preco / 100)::text || ', ' || a_total || ' min)' as o_que
        from par where coalesce(a_ativo, false) and not coalesce(b_ativo, false)
      union all
      select nome, 'sai do catálogo' from par where coalesce(b_ativo, false) and not coalesce(a_ativo, false)
      union all
      select nome, 'preço R$ ' || (b_preco / 100)::text || ' -> R$ ' || (a_preco / 100)::text
        from par where a_ativo and b_ativo and a_preco is distinct from b_preco
      union all
      select nome, case when a_piso then 'passa a ser "a partir de"' else 'deixa de ser "a partir de"' end
        from par where a_ativo and b_ativo and a_piso is distinct from b_piso
      union all
      select nome, 'tempo total ' || b_total || ' -> ' || a_total || ' min'
        from par where a_ativo and b_ativo and a_total is distinct from b_total
      union all
      select nome, 'pausa ' || b_pausa || ' -> ' || a_pausa || ' min'
        from par where a_ativo and b_ativo and a_pausa is distinct from b_pausa
      union all
      select nome, 'variações: ' || coalesce(nullif(b_var, ''), 'nenhuma') || ' -> ' || coalesce(nullif(a_var, ''), 'nenhuma')
        from par where a_ativo and b_ativo and a_var is distinct from b_var
    )
    select coalesce(jsonb_agg(jsonb_build_object('servico', nome, 'mudanca', o_que) order by nome), '[]'::jsonb)
      into v_itens
      from mudancas;

    if exists (
      select (h.weekday::integer, h.starts_at::time, h.ends_at::time) from app.operating_hours h
       where h.tenant_id = p_tenant_id and h.configuration_draft_id = v_rascunho
      except
      select ((x->>'weekday')::integer, (x->>'starts_at')::time, (x->>'ends_at')::time)
        from jsonb_array_elements(coalesce(v_snap->'operatingHours', '[]'::jsonb)) x
    ) or exists (
      select ((x->>'weekday')::integer, (x->>'starts_at')::time, (x->>'ends_at')::time)
        from jsonb_array_elements(coalesce(v_snap->'operatingHours', '[]'::jsonb)) x
      except
      select (h.weekday::integer, h.starts_at::time, h.ends_at::time) from app.operating_hours h
       where h.tenant_id = p_tenant_id and h.configuration_draft_id = v_rascunho
    ) then
      v_itens := v_itens || jsonb_build_array(jsonb_build_object('servico', null, 'mudanca', 'horário de funcionamento mudou'));
    end if;
  end if;

  v_itens := v_itens || coalesce((
    select jsonb_agg(jsonb_build_object('servico', null, 'mudanca', 'regra nova: ' || left(coalesce(ap.title, ap.body), 120)))
      from app.agent_policies ap
     where ap.tenant_id = p_tenant_id and ap.status = 'DRAFT' and ap.aguarda_publicacao), '[]'::jsonb);

  return v_itens;
end;
$function$;

create or replace function public.eddy_o_que_muda_ao_publicar(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$ select app.eddy_o_que_muda_ao_publicar(p_tenant_id); $function$;

revoke all on function app.eddy_o_que_muda_ao_publicar(uuid) from public, anon, authenticated;
revoke all on function public.eddy_o_que_muda_ao_publicar(uuid) from public, anon, authenticated;
grant execute on function public.eddy_o_que_muda_ao_publicar(uuid) to service_role;
