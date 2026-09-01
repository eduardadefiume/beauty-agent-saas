-- O botao "Editar de novo" nao funcionava, e sem ele nao ha como preencher
-- preco: a configuracao publicada e congelada de proposito, e esse botao e o
-- unico caminho de volta para o rascunho.
--
-- Erro real ao tentar destravar a configuracao do piloto:
--
--   null value in column "minimum_duration_minutes" of relation
--   "service_steps" violates not-null constraint
--
-- app.service_steps tem minimum_duration_minutes e maximum_duration_minutes
-- NOT NULL e sem default. As duas funcoes que escrevem etapa --
-- site_start_new_draft, que clona o publicado, e
-- site_replace_configuration_base, que grava o que a tela mandou -- nao citam
-- nenhuma das duas colunas. Elas entraram no schema depois e as funcoes nunca
-- foram atualizadas.
--
-- Consequencia: com qualquer servico que tenha etapa -- ou seja, qualquer
-- salao de verdade -- destravar a configuracao falha E gravar servico falha. O
-- modulo Servicos ficou sem escrita, e ninguem tinha percebido porque o piloto
-- foi cadastrado antes das colunas existirem.
--
-- A correcao e a mesma nos dois lugares: passar as colunas.
--   - No clone, copiar o que ja estava na etapa de origem.
--   - Na gravacao, aceitar o que a tela mandar e, quando ela nao mandar nada,
--     usar a propria duracao. Etapa sem faixa e etapa de duracao fixa, que e
--     como o motor de agenda ja a trata.
do $$
declare
  definicao text;

  clone_antes constant text := $t$    insert into app.service_steps (
      tenant_id, configuration_draft_id, service_id, name, position, duration_minutes, kind,
      customer_presence_required, releases_member
    )
    values (
      rec.tenant_id, new_draft_id, (service_map ->> rec.service_id::text)::uuid, rec.name, rec.position,
      rec.duration_minutes, rec.kind, rec.customer_presence_required, rec.releases_member
    )$t$;

  clone_depois constant text := $t$    insert into app.service_steps (
      tenant_id, configuration_draft_id, service_id, name, position, duration_minutes, kind,
      customer_presence_required, releases_member,
      minimum_duration_minutes, maximum_duration_minutes
    )
    values (
      rec.tenant_id, new_draft_id, (service_map ->> rec.service_id::text)::uuid, rec.name, rec.position,
      rec.duration_minutes, rec.kind, rec.customer_presence_required, rec.releases_member,
      coalesce(rec.minimum_duration_minutes, rec.duration_minutes),
      coalesce(rec.maximum_duration_minutes, rec.duration_minutes)
    )$t$;

  save_antes constant text := $t$insert into app.service_steps (
        tenant_id, configuration_draft_id, service_id, name, position,
        duration_minutes, kind, customer_presence_required, releases_member
      ) values (
        target_tenant_id,
        draft_record.id,
        service_id_value,
        trim(step_item->>'name'),
        (step_item->>'position')::integer,
        (step_item->>'durationMinutes')::integer,
        coalesce(nullif(step_item->>'kind', ''), 'ACTIVE')::app.step_kind,
        coalesce((step_item->>'customerPresenceRequired')::boolean, true),
        coalesce((step_item->>'releasesMember')::boolean, false)
      )$t$;

  save_depois constant text := $t$insert into app.service_steps (
        tenant_id, configuration_draft_id, service_id, name, position,
        duration_minutes, kind, customer_presence_required, releases_member,
        minimum_duration_minutes, maximum_duration_minutes
      ) values (
        target_tenant_id,
        draft_record.id,
        service_id_value,
        trim(step_item->>'name'),
        (step_item->>'position')::integer,
        (step_item->>'durationMinutes')::integer,
        coalesce(nullif(step_item->>'kind', ''), 'ACTIVE')::app.step_kind,
        coalesce((step_item->>'customerPresenceRequired')::boolean, true),
        coalesce((step_item->>'releasesMember')::boolean, false),
        coalesce(nullif(step_item->>'minimumDurationMinutes', '')::integer,
                 (step_item->>'durationMinutes')::integer),
        coalesce(nullif(step_item->>'maximumDurationMinutes', '')::integer,
                 (step_item->>'durationMinutes')::integer)
      )$t$;
begin
  -- 1. O clone do publicado.
  select pg_get_functiondef(p.oid) into definicao
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'site_start_new_draft';

  if definicao is null then
    raise exception 'public.site_start_new_draft nao existe';
  end if;

  if position('minimum_duration_minutes' in definicao) > 0 then
    raise notice 'o clone ja copia a faixa de duracao';
  elsif position(clone_antes in definicao) = 0 then
    raise exception 'o insert de service_steps em site_start_new_draft nao esta como esperado; nada foi alterado';
  else
    execute replace(definicao, clone_antes, clone_depois);
  end if;

  -- 2. A gravacao do que a tela mandou.
  select pg_get_functiondef(p.oid) into definicao
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'site_replace_configuration_base';

  if definicao is null then
    raise exception 'public.site_replace_configuration_base nao existe';
  end if;

  if position('minimum_duration_minutes' in definicao) > 0 then
    raise notice 'a gravacao ja escreve a faixa de duracao';
  elsif position(save_antes in definicao) = 0 then
    raise exception 'o insert de service_steps em site_replace_configuration_base nao esta como esperado; nada foi alterado';
  else
    execute replace(definicao, save_antes, save_depois);
  end if;
end $$;
