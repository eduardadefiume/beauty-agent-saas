-- A classificação sai da tabela e aparece onde ela serve para alguma coisa:
-- na ficha que o dono edita e no contexto que o agente lê.
--
-- Guardar bem e não mostrar é o mesmo que não guardar. São quatro leituras:
--
--   site_load_clients  -- a lista precisa do id da dimensão, não só do nome,
--                         para a tela agrupar sem adivinhar por texto.
--   site_load_client   -- a ficha traz o que já foi respondido, com quem
--                         respondeu e com quanta confiança.
--   site_save_client   -- o que o dono escolhe na tela entra como PESSOA, que
--                         é a resposta que nenhum agente sobrescreve.
--   build_agent_context-- o agente para de ver duas gavetas fixas e passa a
--                         ver a régua inteira daquele salão.

-- ---------------------------------------------------------------------------
-- 1. A lista devolve o id da dimensão junto do nome.
-- ---------------------------------------------------------------------------
do $$
declare
  definicao text := pg_get_functiondef('public.site_load_clients(text,text,uuid,integer)'::regprocedure);
  antes text := '''dimension'', d.name,';
  depois text := '''dimensionId'', d.id,
               ''dimension'', d.name,';
begin
  if position('''dimensionId''' in definicao) > 0 then
    raise notice 'a lista ja traz o id da dimensao, nada a fazer';
    return;
  end if;
  if position(antes in definicao) = 0 then
    raise exception 'site_load_clients nao esta como esperado; nada foi alterado';
  end if;
  execute replace(definicao, antes, depois);
end $$;

-- ---------------------------------------------------------------------------
-- 2. A ficha traz a classificação inteira -- e quem respondeu.
--
-- `source` e `confidence` vão para a tela de propósito. Uma resposta que o
-- motor deu lendo uma foto e uma que o William digitou olhando a cliente na
-- cadeira não valem a mesma coisa, e quem está corrigindo a ficha precisa
-- saber qual é qual antes de decidir se mexe.
-- ---------------------------------------------------------------------------
do $$
declare
  definicao text := pg_get_functiondef('public.site_load_client(text,text,uuid,uuid)'::regprocedure);
  antes text := '''lengthOptionId'', v_perfil.length_option_id,';
  depois text := '''classifications'', coalesce((
      select jsonb_agg(jsonb_build_object(
               ''dimensionId'', c.dimension_id,
               ''dimensionName'', d.name,
               ''optionId'', c.option_id,
               ''optionLabel'', o.label,
               ''confidence'', c.confidence,
               ''source'', c.source,
               ''decidedAt'', c.decided_at
             ) order by d.position)
        from app.client_classifications c
        join app.knowledge_dimensions d on d.id = c.dimension_id
        join app.knowledge_options o on o.id = c.option_id
       where c.profile_id = v_perfil.id
    ), ''[]''::jsonb),
    ''lengthOptionId'', v_perfil.length_option_id,';
begin
  if position('''classifications''' in definicao) > 0 then
    raise notice 'a ficha ja traz as classificacoes, nada a fazer';
    return;
  end if;
  if position(antes in definicao) = 0 then
    raise exception 'site_load_client nao esta como esperado; nada foi alterado';
  end if;
  execute replace(definicao, antes, depois);
end $$;

-- ---------------------------------------------------------------------------
-- 3. O que o dono escolhe na tela entra como resposta de PESSOA.
--
-- DUAS DECISÕES QUE VALEM SER LIDAS.
--
-- A tela deixou de escrever direto em `length_option_id`/`thickness_option_id`.
-- Quem escreve nessas duas colunas agora é só `set_client_classification`, e
-- ele escreve como espelho. Duas mãos gravando o mesmo dado é como ele começa
-- a divergir.
--
-- E o bloco só roda quando o payload TEM a chave `classifications`. O contrato
-- desta função é "o que vem substitui tudo", o que é certo para listas que a
-- tela sempre manda inteiras -- mas apagar a classificação de uma cliente
-- porque uma versão antiga da tela não conhecia o campo seria perder dado por
-- causa de um deploy fora de ordem.
-- ---------------------------------------------------------------------------
create or replace function public.site_save_client(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_profile_id      uuid,
  payload                jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_perfil app.client_profiles;
  v_item jsonb;
  v_removidas text[];
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  select * into v_perfil from app.client_profiles
   where id = target_profile_id and tenant_id = target_tenant_id;
  if not found then
    raise exception 'CLIENT_NOT_FOUND';
  end if;

  update app.client_profiles set
    preferred_name = nullif(trim(coalesce(payload->>'preferredName', '')), ''),
    status = case when coalesce(payload->>'status', '') in ('PRE_CADASTRO', 'COMPLETO', 'ARQUIVADA')
                  then payload->>'status' else status end,
    has_chemistry = case when payload ? 'hasChemistry' then (payload->>'hasChemistry')::boolean end,
    chemistry_kind = nullif(trim(coalesce(payload->>'chemistryKind', '')), ''),
    chemistry_last_at = nullif(payload->>'chemistryLastAt', '')::date,
    chemistry_formol = nullif(payload->>'chemistryFormol', ''),
    has_color = case when payload ? 'hasColor' then (payload->>'hasColor')::boolean end,
    color_last_at = nullif(payload->>'colorLastAt', '')::date,
    tone_wanted = nullif(trim(coalesce(payload->>'toneWanted', '')), ''),
    notes = nullif(trim(coalesce(payload->>'notes', '')), ''),
    photo_consent_granted_at = case
      when coalesce((payload->>'photoConsent')::boolean, false)
        then coalesce(photo_consent_granted_at, statement_timestamp())
      else null end,
    photo_consent_recorded_by = case
      when coalesce((payload->>'photoConsent')::boolean, false) then target_email else null end,
    photo_consent_note = nullif(trim(coalesce(payload->>'photoConsentNote', '')), '')
  where id = target_profile_id;

  if payload ? 'classifications' then
    -- "não anotado" na tela vem como dimensão ausente da lista, e apagar é o
    -- comportamento certo: é assim que o dono desfaz uma resposta errada.
    delete from app.client_classifications
     where profile_id = target_profile_id
       and dimension_id not in (
         select (x->>'dimensionId')::uuid
           from jsonb_array_elements(payload->'classifications') x
          where coalesce(x->>'dimensionId', '') <> ''
            and coalesce(x->>'optionId', '') <> ''
       );

    for v_item in select * from jsonb_array_elements(payload->'classifications') loop
      if coalesce(v_item->>'dimensionId', '') <> '' and coalesce(v_item->>'optionId', '') <> '' then
        perform app.set_client_classification(
          target_tenant_id, target_profile_id,
          (v_item->>'dimensionId')::uuid, (v_item->>'optionId')::uuid, 'PESSOA'
        );
      end if;
    end loop;
  end if;

  delete from app.client_procedures where profile_id = target_profile_id;
  for v_item in select * from jsonb_array_elements(coalesce(payload->'procedures', '[]'::jsonb)) loop
    insert into app.client_procedures (
      tenant_id, profile_id, family, label, times_done, last_done_at,
      cadence_days, cadence_confidence)
    values (
      target_tenant_id, target_profile_id,
      coalesce(nullif(v_item->>'family', ''), 'OUTRO')::app.procedure_family,
      trim(v_item->>'label'),
      coalesce((v_item->>'timesDone')::integer, 1),
      nullif(v_item->>'lastDoneAt', '')::date,
      nullif(v_item->>'cadenceDays', '')::integer,
      coalesce(nullif(v_item->>'cadenceConfidence', ''), 'BAIXA'))
    on conflict (profile_id, family, label) do nothing;
  end loop;

  delete from app.client_visits where profile_id = target_profile_id and appointment_id is null;
  for v_item in select * from jsonb_array_elements(coalesce(payload->'visits', '[]'::jsonb)) loop
    insert into app.client_visits (
      tenant_id, profile_id, occurred_on, description, family,
      duration_minutes, amount_cents, notes)
    values (
      target_tenant_id, target_profile_id,
      (v_item->>'occurredOn')::date,
      coalesce(nullif(trim(v_item->>'description'), ''), 'Atendimento'),
      nullif(v_item->>'family', '')::app.procedure_family,
      nullif(v_item->>'durationMinutes', '')::integer,
      nullif(v_item->>'amountCents', '')::integer,
      nullif(trim(coalesce(v_item->>'notes', '')), ''));
  end loop;

  select coalesce(array_agg(f.storage_path), '{}')
    into v_removidas
    from app.client_photos f
   where f.profile_id = target_profile_id
     and f.storage_path not in (
       select x->>'storagePath' from jsonb_array_elements(coalesce(payload->'photos', '[]'::jsonb)) x
       where coalesce(x->>'storagePath', '') <> ''
     );

  delete from app.client_photos where profile_id = target_profile_id;
  for v_item in select * from jsonb_array_elements(coalesce(payload->'photos', '[]'::jsonb)) loop
    insert into app.client_photos (
      tenant_id, profile_id, kind, storage_path, caption, taken_on, position)
    values (
      target_tenant_id, target_profile_id,
      coalesce(nullif(v_item->>'kind', ''), 'RESULTADO'),
      v_item->>'storagePath',
      nullif(trim(coalesce(v_item->>'caption', '')), ''),
      nullif(v_item->>'takenOn', '')::date,
      coalesce((v_item->>'position')::integer, 0))
    on conflict (tenant_id, storage_path) do nothing;
  end loop;

  return jsonb_build_object('ok', true, 'removedPaths', to_jsonb(v_removidas));
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. O agente passa a ver a régua inteira, não duas gavetas.
--
-- Antes ele recebia `hair: { length, thickness }` -- dois campos que eu escolhi
-- e que não são os campos de nenhum salão em particular. Agora recebe uma lista
-- com o nome que o salão deu à pergunta e o rótulo que o salão deu à resposta.
-- `length` e `thickness` continuam por enquanto, porque o prompt ainda fala
-- deles; a lista é o caminho novo.
-- ---------------------------------------------------------------------------
do $$
declare
  definicao text := pg_get_functiondef('app.build_agent_context(uuid,integer)'::regprocedure);
  antes text := '''thickness'', (select k.label from app.knowledge_options k where k.id = v_perfil.thickness_option_id)
      ),';
  depois text := '''thickness'', (select k.label from app.knowledge_options k where k.id = v_perfil.thickness_option_id),
        ''classificacao'', coalesce((
          select jsonb_agg(jsonb_build_object(
                   ''pergunta'', d.name,
                   ''resposta'', o.label,
                   ''quemRespondeu'', c.source
                 ) order by d.position)
            from app.client_classifications c
            join app.knowledge_dimensions d on d.id = c.dimension_id
            join app.knowledge_options o on o.id = c.option_id
           where c.profile_id = v_perfil.id
        ), ''[]''::jsonb)
      ),';
begin
  if position('''classificacao''' in definicao) > 0 then
    raise notice 'o contexto ja traz a classificacao, nada a fazer';
    return;
  end if;
  if position(antes in definicao) = 0 then
    raise exception 'app.build_agent_context nao esta como esperado; nada foi alterado';
  end if;
  execute replace(definicao, antes, depois);
end $$;
