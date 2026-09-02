-- G5: o banco de conhecimento do produto, e a linha que separa produto de salão.
--
-- Roda dentro de uma transação e termina em rollback: nada do que este teste
-- escreve sobrevive. O último select é o que o operador lê.

begin;

do $$
declare
  v_tenant uuid;
  v_dim    uuid;
  v_fam    uuid;
  v_origin text;
  v_n      integer;
  v_plano  jsonb;
begin
  -- Um salão novo, para provar o que o produto planta em quem chega do zero.
  insert into app.tenants (slug, display_name)
  values ('g5-salao-de-teste', 'Salão de teste G5')
  returning id into v_tenant;

  perform app.seed_tenant_knowledge(v_tenant);

  -- 1. Salão novo herda o vocabulário do produto, marcado como do produto.
  select count(*) into v_n from app.knowledge_dimensions
   where tenant_id = v_tenant and origin = 'PRODUTO';
  if v_n <> (select count(*) from app.product_knowledge_dimensions where seeded) then
    raise exception 'G5.1 salao novo nao herdou as dimensoes do produto (achou %)', v_n;
  end if;

  select count(*) into v_n from app.knowledge_options
   where tenant_id = v_tenant and origin <> 'PRODUTO';
  if v_n <> 0 then
    raise exception 'G5.2 opcao plantada nasceu sem carimbo de produto (% linhas)', v_n;
  end if;

  -- 2. Reordenar não é confirmar: o carimbo não muda.
  select id into v_dim from app.knowledge_dimensions
   where tenant_id = v_tenant and product_code = 'VOLUME';
  update app.knowledge_dimensions set position = position + 10 where id = v_dim;
  select origin into v_origin from app.knowledge_dimensions where id = v_dim;
  if v_origin <> 'PRODUTO' then
    raise exception 'G5.3 reordenar virou ajuste do dono (ficou %)', v_origin;
  end if;

  -- 3. Reescrever as palavras é confirmar: vira ajuste do dono.
  update app.knowledge_dimensions
     set what_to_look_at = 'Quanto o cabelo abre quando ela solta.'
   where id = v_dim;
  select origin into v_origin from app.knowledge_dimensions where id = v_dim;
  if v_origin <> 'PRODUTO_AJUSTADO' then
    raise exception 'G5.4 dono reescreveu e o carimbo nao mudou (ficou %)', v_origin;
  end if;

  -- 4. Plantar duas vezes não desfaz o que o dono escreveu.
  perform app.seed_tenant_knowledge(v_tenant);
  select what_to_look_at into v_origin from app.knowledge_dimensions where id = v_dim;
  if v_origin <> 'Quanto o cabelo abre quando ela solta.' then
    raise exception 'G5.5 plantar de novo apagou a palavra do dono (ficou %)', v_origin;
  end if;

  -- 5. O plano de cor cita a regra da profissão, com o enunciado dela.
  select id into v_fam from app.tone_families
   where tenant_id = v_tenant and product_code = 'LOIRO';
  v_plano := app.color_plan(v_tenant, 6::smallint, 'COLORIDO', 7::smallint, v_fam, false);

  if v_plano->'etapas'->0->>'regra' <> 'TINTA_NAO_CLAREIA_TINTA' then
    raise exception 'G5.6 o plano nao citou a regra que usou (veio %)', v_plano->'etapas'->0;
  end if;
  if jsonb_array_length(v_plano->'regras') < 1 then
    raise exception 'G5.7 o plano nao devolveu o enunciado das regras';
  end if;

  -- 6. Regra arquivada não derruba o plano: a etapa continua, sem a frase.
  update app.product_rules set status = 'ARCHIVED' where code = 'TINTA_NAO_CLAREIA_TINTA';
  v_plano := app.color_plan(v_tenant, 6::smallint, 'COLORIDO', 7::smallint, v_fam, false);
  if v_plano->'etapas'->0->>'etapa' <> 'DESCOLORACAO' then
    raise exception 'G5.8 arquivar a regra tirou a etapa do plano';
  end if;
  if v_plano->'etapas'->0->>'porque' is not null then
    raise exception 'G5.9 regra arquivada continuou explicando';
  end if;

  raise notice 'G5 ok';
end $$;

rollback;

select 'G5_PRODUCT_KNOWLEDGE_INTEGRATION_OK' as result;
