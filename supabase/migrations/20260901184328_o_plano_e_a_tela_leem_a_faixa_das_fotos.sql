-- O plano e a tela passam a ler a faixa das fotos, não da coluna.
--
-- Continuação da correção: se a família é definida por foto, então tudo que
-- consultava `min_level`/`max_level` tem que passar por `app.tone_family_range`,
-- que devolve o que as fotos dizem e só cai na coluna enquanto não houver foto.
--
-- E o aviso muda junto. Antes ele dizia "a faixa ainda é sugestão do sistema".
-- Agora ele diz a coisa útil: "esta família ainda não tem foto nenhuma" -- que
-- é uma tarefa que o William resolve em trinta segundos, não um alerta abstrato.

create or replace function app.color_plan(
  p_tenant_id     uuid,
  p_from_level    smallint,
  p_current_state text,
  p_to_level      smallint,
  p_family_id     uuid default null,
  p_has_chemistry boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_familia   app.tone_families;
  v_faixa     record;
  v_fotos     integer := 0;
  v_fundo     text;
  v_lift      integer;
  v_valores   jsonb := '{}'::jsonb;
  v_p         record;
  v_usados    text[] := '{}';
  v_sugeridos text[] := '{}';
  v_etapas    jsonb := '[]'::jsonb;
  v_avisos    text[] := '{}';
  v_minutos   numeric := 0;
  v_reais     numeric := 0;
  v_descolore boolean := false;
  v_prepig    boolean := false;
  v_matiza    boolean := false;
  v_teste     boolean := false;
begin
  if p_from_level is null or p_to_level is null
     or p_from_level not between 1 and 10 or p_to_level not between 1 and 10 then
    return jsonb_build_object('ok', false, 'reason', 'ALTURA_DE_TOM_INVALIDA');
  end if;
  if coalesce(p_current_state, '') not in ('VIRGEM', 'COLORIDO', 'DESCOLORIDO') then
    return jsonb_build_object('ok', false, 'reason', 'ESTADO_DO_FIO_INVALIDO');
  end if;

  if p_family_id is not null then
    select * into v_familia from app.tone_families
     where id = p_family_id and tenant_id = p_tenant_id and status = 'ACTIVE';
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'FAMILIA_NAO_E_DESTE_SALAO');
    end if;
    select * into v_faixa from app.tone_family_range(p_family_id);
    select count(*) into v_fotos from app.tone_family_photos
     where family_id = p_family_id and estimated_level is not null;
  end if;

  for v_p in
    select key, coalesce(answer_value, suggested_value) as valor,
           (answer_value is not null) as respondido
      from app.color_policies where tenant_id = p_tenant_id
  loop
    v_valores := v_valores || jsonb_build_object(
      v_p.key, jsonb_build_object('valor', v_p.valor, 'respondido', v_p.respondido));
  end loop;

  if v_valores = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_SEM_MODELO_DE_COR');
  end if;

  select underlying_pigment into v_fundo from app.tone_levels where level = p_to_level;
  v_lift := p_to_level - p_from_level;

  if v_lift > 0 then
    v_usados := v_usados || 'CLAREIA_SEM_DESCOLORIR'::text;
    if v_lift > (v_valores->'CLAREIA_SEM_DESCOLORIR'->>'valor')::numeric then
      v_descolore := true;
      v_etapas := v_etapas || jsonb_build_object(
        'etapa', 'DESCOLORACAO',
        'porque', format('São %s níveis de clareamento, acima do que a coloração daqui clareia sozinha.', v_lift));
    elsif p_current_state = 'COLORIDO' then
      v_descolore := true;
      v_etapas := v_etapas || jsonb_build_object(
        'etapa', 'DESCOLORACAO',
        'porque', 'O cabelo já é colorido, e tinta não clareia tinta.');
    end if;
  end if;

  if p_current_state = 'DESCOLORIDO' and (v_lift < 0 or coalesce(v_familia.needs_warm_base, false)) then
    v_prepig := true;
    v_etapas := v_etapas || jsonb_build_object(
      'etapa', 'PRE_PIGMENTACAO',
      'porque', case when v_lift < 0
                  then 'O cabelo está descolorido e vai escurecer: sem repor o fundo, a cor não fixa e esverdeia.'
                  else 'O cabelo está descolorido e o tom pedido é quente: sem repor o fundo, o vermelho não segura.' end);
  end if;

  if v_descolore and not coalesce(v_familia.needs_warm_base, false) then
    v_matiza := true;
    v_etapas := v_etapas || jsonb_build_object(
      'etapa', 'MATIZACAO',
      'porque', format('Clareando até %s aparece fundo %s, e é ele que a matização neutraliza.', p_to_level, v_fundo));
  end if;

  v_usados := v_usados || 'TESTE_A_PARTIR_DE'::text;
  if v_lift >= (v_valores->'TESTE_A_PARTIR_DE'->>'valor')::numeric then
    v_teste := true;
  end if;
  if v_descolore then v_teste := true; end if;
  if p_has_chemistry then
    v_usados := v_usados || 'QUIMICA_EXIGE_TESTE'::text;
    if (v_valores->'QUIMICA_EXIGE_TESTE'->>'valor')::numeric = 1 then v_teste := true; end if;
  end if;

  if v_descolore then
    v_usados := v_usados || 'MINUTOS_POR_NIVEL'::text || 'REAIS_POR_NIVEL'::text;
    v_minutos := v_minutos + v_lift * (v_valores->'MINUTOS_POR_NIVEL'->>'valor')::numeric;
    v_reais   := v_reais   + v_lift * (v_valores->'REAIS_POR_NIVEL'->>'valor')::numeric;
  end if;
  if v_prepig then
    v_usados := v_usados || 'MINUTOS_PRE_PIGMENTACAO'::text || 'REAIS_PRE_PIGMENTACAO'::text;
    v_minutos := v_minutos + (v_valores->'MINUTOS_PRE_PIGMENTACAO'->>'valor')::numeric;
    v_reais   := v_reais   + (v_valores->'REAIS_PRE_PIGMENTACAO'->>'valor')::numeric;
  end if;
  if v_matiza then
    v_usados := v_usados || 'MINUTOS_MATIZACAO'::text || 'REAIS_MATIZACAO'::text;
    v_minutos := v_minutos + (v_valores->'MINUTOS_MATIZACAO'->>'valor')::numeric;
    v_reais   := v_reais   + (v_valores->'REAIS_MATIZACAO'->>'valor')::numeric;
  end if;
  v_minutos := v_minutos + coalesce(v_familia.extra_minutes, 0);
  v_reais   := v_reais   + coalesce(v_familia.extra_price_minor, 0) / 100.0;

  -- A faixa vem das fotos que o dono classificou.
  if v_familia.id is not null and v_faixa.min_level is not null
     and p_to_level not between v_faixa.min_level and v_faixa.max_level then
    v_avisos := v_avisos || format(
      'O tom %s está fora da faixa que este salão chama de %s (%s a %s%s).',
      p_to_level, v_familia.name, v_faixa.min_level, v_faixa.max_level,
      case when v_faixa.from_photos then ', pelas fotos cadastradas' else '' end);
  end if;
  -- O aviso útil não é "falta confirmar", é "falta foto": é a foto que ensina
  -- ao sistema o que este salão chama de ruivo.
  if v_familia.id is not null and v_fotos = 0 then
    v_avisos := v_avisos || format(
      'A família %s ainda não tem nenhuma foto cadastrada, então o sistema não aprendeu o que este salão chama assim.',
      v_familia.name);
  end if;

  select coalesce(array_agg(distinct k), '{}')
    into v_sugeridos
    from unnest(v_usados) k
   where (v_valores->k->>'respondido')::boolean is not true;

  return jsonb_build_object(
    'ok', true,
    'deNivel', p_from_level,
    'paraNivel', p_to_level,
    'clareamento', v_lift,
    'estadoDoFio', p_current_state,
    'familia', case when v_familia.id is null then null else v_familia.name end,
    'faixaDaFamilia', case when v_familia.id is null then null else jsonb_build_object(
      'de', v_faixa.min_level, 'ate', v_faixa.max_level,
      'veioDasFotos', coalesce(v_faixa.from_photos, false), 'fotos', v_fotos) end,
    'fundoQueAparece', v_fundo,
    'etapas', v_etapas,
    'testeDeMecha', v_teste,
    'tempoAMaisMinutos', v_minutos::integer,
    'precoAMaisMinor', (v_reais * 100)::integer,
    'avisos', to_jsonb(v_avisos),
    'aindaSugerido', to_jsonb(v_sugeridos)
  );
end;
$function$;

grant execute on function app.color_plan(uuid, smallint, text, smallint, uuid, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- A tela passa a receber as fotos de cada família.
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
               'needsWarmBase', f.needs_warm_base,
               'extraMinutes', f.extra_minutes, 'extraPriceMinor', f.extra_price_minor,
               -- A faixa não é campo: é o que as fotos dizem.
               'rangeMin', r.min_level, 'rangeMax', r.max_level,
               'rangeFromPhotos', r.from_photos,
               'photos', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', ph.id, 'storagePath', ph.storage_path,
                          'caption', ph.caption,
                          'estimatedLevel', ph.estimated_level,
                          'levelSource', ph.level_source,
                          'readAt', ph.read_at, 'readError', ph.read_error
                        ) order by ph.position, ph.created_at)
                   from app.tone_family_photos ph where ph.family_id = f.id
               ), '[]'::jsonb)
             ) order by f.position, f.name)
        from app.tone_families f
        left join lateral app.tone_family_range(f.id) r on true
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

grant execute on function public.site_load_color_model(text, text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Registrar uma foto que o dono subiu, já dizendo a que família ela pertence.
--
-- Só registra o caminho: o arquivo sobe pela rota do site, com o caminho
-- montado no servidor. E a altura de tom NÃO vem daqui -- ela vai ser lida da
-- foto pelo motor. Aceitar altura na hora do cadastro seria reabrir a porta que
-- esta correção fechou.
-- ---------------------------------------------------------------------------
create or replace function public.site_add_tone_family_photo(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_family_id       uuid,
  target_storage_path    text,
  target_caption         text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  if not exists (select 1 from app.tone_families
                  where id = target_family_id and tenant_id = target_tenant_id) then
    raise exception 'TONE_FAMILY_NOT_FOUND';
  end if;

  -- O caminho tem que começar pela pasta do próprio salão. É a mesma trava que
  -- as políticas do balde aplicam, repetida aqui para o registro nunca apontar
  -- para o arquivo de outro negócio.
  if position(target_tenant_id::text || '/' in target_storage_path) <> 1 then
    raise exception 'STORAGE_PATH_FORA_DO_TENANT';
  end if;

  insert into app.tone_family_photos (tenant_id, family_id, storage_path, caption)
  values (target_tenant_id, target_family_id, target_storage_path,
          nullif(trim(coalesce(target_caption, '')), ''))
  on conflict (tenant_id, storage_path) do update
    set family_id = excluded.family_id, updated_at = statement_timestamp()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'photoId', v_id);
end;
$function$;

revoke all on function public.site_add_tone_family_photo(text, text, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.site_add_tone_family_photo(text, text, uuid, uuid, text, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Apagar uma foto, ou corrigir a altura que o motor leu nela.
--
-- Correção de gente vira `level_source = 'PESSOA'`, e é isso que impede o motor
-- de passar por cima dela numa releitura -- mesma regra da classificação por
-- foto da cliente.
-- ---------------------------------------------------------------------------
create or replace function public.site_update_tone_family_photo(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_photo_id        uuid,
  target_remove          boolean default false,
  target_level           smallint default null,
  target_caption         text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_path text;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  if target_remove then
    delete from app.tone_family_photos
     where id = target_photo_id and tenant_id = target_tenant_id
    returning storage_path into v_path;
    if v_path is null then
      return jsonb_build_object('ok', false, 'reason', 'FOTO_NAO_ENCONTRADA');
    end if;
    -- Devolve o caminho para o site apagar o arquivo do balde: guardar o
    -- registro sem o arquivo, ou o arquivo sem o registro, é lixo dos dois
    -- jeitos.
    return jsonb_build_object('ok', true, 'removedPath', v_path);
  end if;

  update app.tone_family_photos
     set estimated_level = coalesce(target_level, estimated_level),
         level_source = case when target_level is not null then 'PESSOA' else level_source end,
         caption = case when target_caption is not null
                        then nullif(trim(target_caption), '') else caption end,
         updated_at = statement_timestamp()
   where id = target_photo_id and tenant_id = target_tenant_id;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'FOTO_NAO_ENCONTRADA');
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.site_update_tone_family_photo(text, text, uuid, uuid, boolean, smallint, text)
  from public, anon, authenticated;
grant execute on function public.site_update_tone_family_photo(text, text, uuid, uuid, boolean, smallint, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Gravar a família deixa de aceitar faixa -- e deixa de ter "confirmada".
--
-- As duas coisas saem pelo mesmo motivo: quem responde o que é cada família
-- agora é a foto. Faixa digitada abriria de novo a porta que esta correção
-- fechou, e um selo de "confirmada" separado das fotos seria um segundo lugar
-- para a mesma verdade -- que é como duas verdades começam a divergir.
--
-- O que sobra para o dono editar na família é o que continua sendo só dele:
-- a descrição, o tempo e o preço a mais, e se ela vive do fundo quente.
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
       set needs_warm_base = coalesce((v_item->>'needsWarmBase')::boolean, f.needs_warm_base),
           extra_minutes = case when v_item ? 'extraMinutes'
                                then nullif(v_item->>'extraMinutes', '')::integer
                                else f.extra_minutes end,
           extra_price_minor = case when v_item ? 'extraPriceMinor'
                                then nullif(v_item->>'extraPriceMinor', '')::integer
                                else f.extra_price_minor end,
           description = coalesce(nullif(trim(coalesce(v_item->>'description', '')), ''), f.description),
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

grant execute on function public.site_save_color_model(text, text, uuid, jsonb) to service_role;

-- As colunas de faixa param de ser usadas como resposta do dono. Ficam como
-- semente: enquanto a família não tiver foto, é delas que sai a faixa.
comment on column app.tone_families.min_level is
  'Semente. A faixa de verdade sai das fotos (app.tone_family_range); esta coluna so vale enquanto a familia nao tiver foto lida.';
comment on column app.tone_families.max_level is
  'Semente. A faixa de verdade sai das fotos (app.tone_family_range); esta coluna so vale enquanto a familia nao tiver foto lida.';
comment on column app.tone_families.answered_at is
  'Herdado do desenho anterior, em que o dono confirmava a faixa digitada. Nao e mais escrito: quem responde o que e cada familia agora e a foto.';
