-- O plano de cor para de carregar a explicação dentro do IF.
--
-- "Tinta não clareia tinta" é conhecimento de cabeleireiro, não é lógica de
-- programa. Estava escrito como literal de plpgsql no meio de um IF, e por
-- isso mudar uma palavra dessa frase exigia migração e deploy -- exatamente o
-- que 20260831120000 resolveu para o prompt do agente.
--
-- Daqui para a frente a etapa continua sendo decidida em código, porque QUANDO
-- descolorir é invariante e não pode depender de dado editável. O que sai do
-- código é o PORQUÊ: a frase vem de `app.product_rules`, e o plano passa a
-- devolver também qual regra usou, com o enunciado dela.
--
-- Isso muda o que o dono vê. Antes o plano dizia "entra descoloração" e uma
-- frase solta. Agora ele diz que regra da profissão levou àquilo, e o dono
-- pode discordar de uma regra nomeada -- que é a conversa que interessa.

create or replace function app.regra_diz(p_code text, p_marcas jsonb default '{}'::jsonb)
returns text
language plpgsql
stable
set search_path to ''
as $function$
declare
  v_texto text;
  v_chave text;
begin
  select coalesce(r.explains, r.statement) into v_texto
    from app.product_rules r where r.code = p_code and r.status = 'ACTIVE';

  -- Regra arquivada ou apagada não pode derrubar o plano: a etapa continua
  -- certa, só fica sem a frase bonita.
  if v_texto is null then
    return null;
  end if;

  -- Substituição por marcação nomeada, e não por format(): marcação que não
  -- vier neste caso fica como está, em vez de estourar por argumento faltando.
  for v_chave in select key from jsonb_each_text(p_marcas) loop
    v_texto := replace(v_texto, '{' || v_chave || '}', coalesce(p_marcas->>v_chave, ''));
  end loop;

  return v_texto;
end;
$function$;

grant execute on function app.regra_diz(text, jsonb) to service_role;

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
  v_regras    text[] := '{}';
  v_etapas    jsonb := '[]'::jsonb;
  v_avisos    text[] := '{}';
  v_minutos   numeric := 0;
  v_reais     numeric := 0;
  v_descolore boolean := false;
  v_prepig    boolean := false;
  v_matiza    boolean := false;
  v_teste     boolean := false;
  v_regra     text;
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

  -- ---- Descoloração -------------------------------------------------------
  -- Duas portas para a mesma etapa, e a segunda é a que mais surpreende
  -- cliente: tinta não clareia tinta.
  if v_lift > 0 then
    v_usados := v_usados || 'CLAREIA_SEM_DESCOLORIR'::text;
    v_regra := null;
    if v_lift > (v_valores->'CLAREIA_SEM_DESCOLORIR'->>'valor')::numeric then
      v_regra := 'CLAREAMENTO_ACIMA_DO_LIMITE';
    elsif p_current_state = 'COLORIDO' then
      v_regra := 'TINTA_NAO_CLAREIA_TINTA';
    end if;
    if v_regra is not null then
      v_descolore := true;
      v_regras := v_regras || v_regra;
      v_etapas := v_etapas || jsonb_build_object(
        'etapa', 'DESCOLORACAO',
        'regra', v_regra,
        'porque', app.regra_diz(v_regra, jsonb_build_object('niveis', v_lift)));
    end if;
  end if;

  -- ---- Pré-pigmentação ----------------------------------------------------
  if p_current_state = 'DESCOLORIDO' and (v_lift < 0 or coalesce(v_familia.needs_warm_base, false)) then
    v_prepig := true;
    v_regra := case when v_lift < 0
                 then 'ESCURECER_SOBRE_DESCOLORIDO'
                 else 'QUENTE_SOBRE_DESCOLORIDO' end;
    v_regras := v_regras || v_regra;
    v_etapas := v_etapas || jsonb_build_object(
      'etapa', 'PRE_PIGMENTACAO',
      'regra', v_regra,
      'porque', app.regra_diz(v_regra));
  end if;

  -- ---- Matização ----------------------------------------------------------
  -- Só depois de clarear, e não quando a família VIVE do fundo quente. O caso
  -- em que ela NÃO entra também é conhecimento: fica registrado como regra
  -- usada, senão o dono lê um plano sem matização e não sabe se foi decisão
  -- ou esquecimento.
  if v_descolore then
    if not coalesce(v_familia.needs_warm_base, false) then
      v_matiza := true;
      v_regras := v_regras || 'FUNDO_DE_CLAREAMENTO'::text;
      v_etapas := v_etapas || jsonb_build_object(
        'etapa', 'MATIZACAO',
        'regra', 'FUNDO_DE_CLAREAMENTO',
        'porque', app.regra_diz('FUNDO_DE_CLAREAMENTO',
          jsonb_build_object('tom', p_to_level, 'fundo', v_fundo)));
    else
      v_regras := v_regras || 'FAMILIA_QUENTE_NAO_MATIZA'::text;
      v_avisos := v_avisos || app.regra_diz('FAMILIA_QUENTE_NAO_MATIZA',
        jsonb_build_object('familia', v_familia.name));
    end if;
  end if;

  -- ---- Teste de mecha -----------------------------------------------------
  v_usados := v_usados || 'TESTE_A_PARTIR_DE'::text;
  if v_lift >= (v_valores->'TESTE_A_PARTIR_DE'->>'valor')::numeric then
    v_teste := true;
  end if;
  if v_descolore then v_teste := true; end if;
  if p_has_chemistry then
    v_usados := v_usados || 'QUIMICA_EXIGE_TESTE'::text;
    if (v_valores->'QUIMICA_EXIGE_TESTE'->>'valor')::numeric = 1 then
      v_teste := true;
      v_regras := v_regras || 'QUIMICA_NAO_SAI_SOZINHA'::text || 'QUIMICA_MUDA_A_COR'::text;
    end if;
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

  if v_familia.id is not null and v_faixa.min_level is not null
     and p_to_level not between v_faixa.min_level and v_faixa.max_level then
    v_avisos := v_avisos || format(
      'O tom %s está fora da faixa que este salão chama de %s (%s a %s%s).',
      p_to_level, v_familia.name, v_faixa.min_level, v_faixa.max_level,
      case when v_faixa.from_photos then ', pelas fotos cadastradas' else '' end);
  end if;
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
    'aindaSugerido', to_jsonb(v_sugeridos),
    -- As regras da profissão que este plano usou, com o enunciado. É o que o
    -- agente cita quando a cliente pergunta "por que preciso descolorir?".
    'regras', coalesce((
      select jsonb_agg(jsonb_build_object(
               'codigo', r.code, 'titulo', r.title, 'diz', r.statement
             ) order by r.position)
        from app.product_rules r
       where r.code = any(v_regras) and r.status = 'ACTIVE'
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function app.color_plan(uuid, smallint, text, smallint, uuid, boolean) to service_role;
