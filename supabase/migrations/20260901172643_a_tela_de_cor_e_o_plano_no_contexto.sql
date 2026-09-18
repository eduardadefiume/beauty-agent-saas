-- A tela onde o William responde, e o plano chegando ao agente.
--
-- Modelo de cor é OPERAÇÃO, não configuração: fica fora do ciclo de
-- rascunho/publicação, pela mesma razão que a ficha da cliente ficou. O William
-- corrigindo às 11h o tempo da matização precisa valer no atendimento das
-- 11h05, não na próxima publicação.

-- ---------------------------------------------------------------------------
-- Ler: a escala (global), as famílias e as perguntas deste salão.
--
-- Devolve `answered` separado de `value` de propósito. A tela precisa mostrar
-- diferente o que o William respondeu e o que ainda é sugestão minha -- senão
-- ele abre a tela, vê tudo preenchido e não responde nada, que é exatamente o
-- oposto do que "monta a estrutura para ele só responder" quer dizer.
-- ---------------------------------------------------------------------------
create or replace function public.site_load_color_model(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return jsonb_build_object(
    'levels', coalesce((
      select jsonb_agg(jsonb_build_object(
               'level', l.level, 'name', l.name, 'underlyingPigment', l.underlying_pigment
             ) order by l.level)
        from app.tone_levels l
    ), '[]'::jsonb),
    'families', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'name', f.name, 'description', f.description,
               'minLevel', f.min_level, 'maxLevel', f.max_level,
               'needsWarmBase', f.needs_warm_base,
               'extraMinutes', f.extra_minutes, 'extraPriceMinor', f.extra_price_minor,
               'answered', f.answered_at is not null,
               'answeredAt', f.answered_at
             ) order by f.position, f.name)
        from app.tone_families f
       where f.tenant_id = target_tenant_id and f.status = 'ACTIVE'
    ), '[]'::jsonb),
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'key', p.key, 'question', p.question, 'helper', p.helper,
               'unit', p.unit,
               'suggestedValue', p.suggested_value,
               'answerValue', p.answer_value,
               'answered', p.answer_value is not null,
               'answeredAt', p.answered_at
             ) order by p.position)
        from app.color_policies p
       where p.tenant_id = target_tenant_id
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.site_load_color_model(text, text, uuid) from public, anon, authenticated;
grant execute on function public.site_load_color_model(text, text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Gravar as respostas.
--
-- NÃO é payload-substitui-tudo. Aqui é o contrário do resto do sistema, e de
-- propósito: só as linhas que vierem no corpo são tocadas, e cada uma só nos
-- campos que vierem. Uma tela que manda a família inteira toda vez apagaria a
-- resposta do William no dia em que eu adicionasse um campo novo que ela ainda
-- não conhece. Respostas de dono são caras demais para arriscar isso.
--
-- `answered_at` nasce aqui, no servidor. Data de confirmação que o navegador
-- escolhe não é prova de que alguém confirmou.
-- ---------------------------------------------------------------------------
create or replace function public.site_save_color_model(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  payload                jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_item        jsonb;
  v_familias    integer := 0;
  v_respostas   integer := 0;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  for v_item in select * from jsonb_array_elements(coalesce(payload->'families', '[]'::jsonb)) loop
    update app.tone_families f
       set min_level = coalesce(nullif(v_item->>'minLevel', '')::smallint, f.min_level),
           max_level = coalesce(nullif(v_item->>'maxLevel', '')::smallint, f.max_level),
           needs_warm_base = coalesce((v_item->>'needsWarmBase')::boolean, f.needs_warm_base),
           extra_minutes = case when v_item ? 'extraMinutes'
                                then nullif(v_item->>'extraMinutes', '')::integer
                                else f.extra_minutes end,
           extra_price_minor = case when v_item ? 'extraPriceMinor'
                                then nullif(v_item->>'extraPriceMinor', '')::integer
                                else f.extra_price_minor end,
           description = coalesce(nullif(trim(coalesce(v_item->>'description', '')), ''), f.description),
           -- Confirmar é um ato: só marca quando a tela disser que foi confirmada.
           answered_at = case when coalesce((v_item->>'answered')::boolean, false)
                              then coalesce(f.answered_at, statement_timestamp())
                              else null end,
           answered_by = case when coalesce((v_item->>'answered')::boolean, false)
                              then target_email else null end,
           updated_at = statement_timestamp()
     where f.tenant_id = target_tenant_id
       and f.id = nullif(v_item->>'id', '')::uuid;
    if found then v_familias := v_familias + 1; end if;
  end loop;

  for v_item in select * from jsonb_array_elements(coalesce(payload->'questions', '[]'::jsonb)) loop
    update app.color_policies p
       set answer_value = nullif(v_item->>'answerValue', '')::numeric,
           answered_at = case when nullif(v_item->>'answerValue', '') is null
                              then null else statement_timestamp() end,
           answered_by = case when nullif(v_item->>'answerValue', '') is null
                              then null else target_email end,
           updated_at = statement_timestamp()
     where p.tenant_id = target_tenant_id
       and p.key = v_item->>'key';
    if found then v_respostas := v_respostas + 1; end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'familiasAtualizadas', v_familias, 'respostasAtualizadas', v_respostas);
end;
$function$;

revoke all on function public.site_save_color_model(text, text, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.site_save_color_model(text, text, uuid, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- O vocabulário de cor entra no contexto do agente.
--
-- Só o vocabulário, não o plano: o plano depende de saber a altura de tom de
-- HOJE do cabelo dela e o tom que ela quer, e nenhum dos dois está na ficha
-- ainda. O que entra agora é o que responde a pergunta "qual tom se encaixa em
-- ruivo" -- as famílias deste salão e a faixa de cada uma -- mais a escala, que
-- é o que dá ao agente uma linguagem para conversar sobre tom sem inventar.
-- ---------------------------------------------------------------------------
do $$
declare
  definicao text := pg_get_functiondef('app.build_agent_context(uuid,integer)'::regprocedure);
  antes text := '''statusArts'',';
  depois text := '''coresDoSalao'', coalesce((
          select jsonb_agg(jsonb_build_object(
                   ''familia'', f.name,
                   ''oQueE'', f.description,
                   ''daAlturaDeTom'', f.min_level,
                   ''ateAlturaDeTom'', f.max_level,
                   ''viveDoFundoQuente'', f.needs_warm_base,
                   ''confirmadoPeloDono'', f.answered_at is not null
                 ) order by f.position, f.name)
            from app.tone_families f
           where f.tenant_id = v_c.tenant_id and f.status = ''ACTIVE''
        ), ''[]''::jsonb),
        ''statusArts'',';
begin
  if position('''coresDoSalao''' in definicao) > 0 then
    raise notice 'o contexto ja traz as cores do salao, nada a fazer';
    return;
  end if;
  if position(antes in definicao) = 0 then
    raise exception 'app.build_agent_context nao esta como esperado; nada foi alterado';
  end if;
  execute replace(definicao, antes, depois);
end $$;
