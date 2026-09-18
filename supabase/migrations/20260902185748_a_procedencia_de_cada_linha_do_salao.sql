-- ETAPA 4, parte 2: de onde veio cada linha do salão.
--
-- A parte 1 criou o banco de conhecimento do produto. Aqui o produto entra
-- dentro de cada salão, e cada linha plantada fica marcada como plantada.

-- ---------------------------------------------------------------------------
-- 4. De onde veio cada linha do salão
-- ---------------------------------------------------------------------------
--
-- PRODUTO          o produto plantou e o dono nunca mexeu. Palpite, não resposta.
-- PRODUTO_AJUSTADO o produto plantou e o dono reescreveu. Vale como resposta.
-- SALAO            o dono criou do zero. Vale como resposta.
--
-- `color_policies` fica de fora de propósito: a pergunta ali é sempre do
-- produto, e quem já responde "o dono confirmou?" naquela tabela é
-- `answered_at`. Criar uma segunda coluna dizendo a mesma coisa daria duas
-- versões da verdade.

do $$
declare v_tabela text;
begin
  foreach v_tabela in array array['knowledge_dimensions', 'knowledge_options', 'tone_families'] loop
    execute format(
      'alter table app.%I
         add column if not exists origin text not null default ''SALAO'',
         add column if not exists product_code text', v_tabela);
    execute format(
      'alter table app.%I drop constraint if exists %I', v_tabela, v_tabela || '_origin_check');
    execute format(
      'alter table app.%I add constraint %I
         check (origin in (''PRODUTO'', ''PRODUTO_AJUSTADO'', ''SALAO''))',
      v_tabela, v_tabela || '_origin_check');
  end loop;
end $$;

alter table app.color_policies
  add column if not exists product_key text references app.product_color_questions(key) on delete set null;

update app.color_policies p
   set product_key = p.key
  from app.product_color_questions q
 where q.key = p.key and p.product_key is null;

-- O dono mexeu no que herdou: isso deixa de ser palpite do produto.
--
-- Vai num gatilho e não dentro das RPCs porque a tela não é o único caminho:
-- o onboarding por conversa vai escrever nessas tabelas também, e regra de
-- procedência que depende de alguém lembrar de aplicar é regra que se perde.
-- Mudar posição não conta: reordenar não é confirmar.
create or replace function app.marcar_ajuste_do_dono()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.origin = 'PRODUTO' then
    if to_jsonb(new) - 'position' - 'updated_at' - 'origin'
       is distinct from to_jsonb(old) - 'position' - 'updated_at' - 'origin' then
      new.origin := 'PRODUTO_AJUSTADO';
    end if;
  end if;
  return new;
end;
$function$;

do $$
declare v_tabela text;
begin
  foreach v_tabela in array array['knowledge_dimensions', 'knowledge_options', 'tone_families'] loop
    execute format('drop trigger if exists marcar_ajuste_do_dono on app.%I', v_tabela);
    execute format(
      'create trigger marcar_ajuste_do_dono before update on app.%I
         for each row execute function app.marcar_ajuste_do_dono()', v_tabela);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Plantar o produto dentro de um salão
-- ---------------------------------------------------------------------------

create or replace function app.seed_tenant_knowledge(p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_dimensoes integer := 0;
  v_opcoes    integer := 0;
  v_familias  integer := 0;
  v_perguntas integer := 0;
  v_n         integer;
begin
  if not exists (select 1 from app.tenants t where t.id = p_tenant_id) then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_NAO_EXISTE');
  end if;

  -- `do nothing` em toda parte: plantar duas vezes não pode desfazer o que o
  -- dono escreveu entre uma vez e a outra.
  --
  -- E vocabulário só entra em salão que ainda não tem nenhum. Ponto de partida
  -- serve para quem não partiu; empurrar Curvatura e Espessura num salão que
  -- já escolheu observar só Volume não é ajudar, é mudar o que o agente
  -- pergunta à cliente sem ninguém ter pedido -- cada dimensão ativa vira uma
  -- pendência em `client_profile_missing`.
  if not exists (
    select 1 from app.knowledge_dimensions d where d.tenant_id = p_tenant_id
  ) then
    insert into app.knowledge_dimensions
      (tenant_id, name, what_to_look_at, position, origin, product_code)
    select p_tenant_id, d.name, d.what_to_look_at, d.position, 'PRODUTO', d.code
      from app.product_knowledge_dimensions d
     where d.seeded
    on conflict (tenant_id, name) do nothing;
    get diagnostics v_dimensoes = row_count;
  end if;

  insert into app.knowledge_options
    (tenant_id, dimension_id, label, description, position, origin, product_code)
  select p_tenant_id, td.id, o.label, o.description, o.position, 'PRODUTO', o.code
    from app.product_knowledge_options o
    join app.product_knowledge_dimensions d on d.code = o.dimension_code and d.seeded
    join app.knowledge_dimensions td
      on td.tenant_id = p_tenant_id and td.product_code = d.code
  on conflict (dimension_id, label) do nothing;
  get diagnostics v_opcoes = row_count;

  insert into app.tone_families
    (tenant_id, name, description, min_level, max_level, needs_warm_base, position, origin, product_code)
  select p_tenant_id, f.name, f.description, f.min_level, f.max_level,
         f.needs_warm_base, f.position, 'PRODUTO', f.code
    from app.product_tone_families f
  on conflict (tenant_id, name) do nothing;
  get diagnostics v_familias = row_count;

  insert into app.color_policies
    (tenant_id, key, question, helper, unit, suggested_value, position, product_key)
  select p_tenant_id, q.key, q.question, q.helper, q.unit, q.suggested_value, q.position, q.key
    from app.product_color_questions q
  on conflict (tenant_id, key) do nothing;
  get diagnostics v_perguntas = row_count;

  -- Mesmo sem plantar nada, o que o salão já tem e coincide com o produto
  -- ganha a etiqueta: é linha que ninguém escolheu, veio do padrão.
  update app.knowledge_dimensions t
     set product_code = d.code
    from app.product_knowledge_dimensions d
   where t.tenant_id = p_tenant_id and t.product_code is null and t.name = d.name;

  update app.knowledge_options t
     set product_code = o.code
    from app.product_knowledge_options o
    join app.product_knowledge_dimensions d on d.code = o.dimension_code
    join app.knowledge_dimensions td on td.product_code = d.code and td.tenant_id = p_tenant_id
   where t.tenant_id = p_tenant_id and t.product_code is null
     and t.dimension_id = td.id and t.label = o.label;

  -- Salão que já existia herdou as famílias antes desta migração e está sem
  -- procedência. Se o nome bate com o do produto e o dono não respondeu nada,
  -- é linha plantada, não escrita.
  update app.tone_families t
     set origin = 'PRODUTO', product_code = f.code
    from app.product_tone_families f
   where t.tenant_id = p_tenant_id
     and t.product_code is null
     and t.answered_at is null
     and t.name = f.name;
  get diagnostics v_n = row_count;

  return jsonb_build_object(
    'ok', true,
    'dimensoesCriadas', v_dimensoes, 'opcoesCriadas', v_opcoes,
    'familiasCriadas', v_familias, 'perguntasCriadas', v_perguntas,
    'familiasAdotadas', v_n
  );
end;
$function$;

revoke all on function app.seed_tenant_knowledge(uuid) from public, anon, authenticated;
grant execute on function app.seed_tenant_knowledge(uuid) to service_role;

-- `seed_color_model` continua existindo porque já tem chamador, mas para de
-- carregar as famílias e as perguntas no corpo: agora ela lê o produto.
create or replace function app.seed_color_model(p_tenant_id uuid)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select app.seed_tenant_knowledge(p_tenant_id);
$function$;

revoke all on function app.seed_color_model(uuid) from public, anon, authenticated;
grant execute on function app.seed_color_model(uuid) to service_role;

-- Os salões que já existem recebem a procedência e o que ainda não tinham.
-- O piloto tem vocabulário escrito pela Duda: `do nothing` preserva.
do $$
declare v_tenant uuid;
begin
  for v_tenant in select id from app.tenants order by created_at loop
    perform app.seed_tenant_knowledge(v_tenant);
  end loop;
end $$;
