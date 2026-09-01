-- O plano de cor: o que precisa ser feito para sair do cabelo de hoje e chegar
-- no tom que ela quer.
--
-- POR QUE É FUNÇÃO E NÃO PROMPT. Isto é a regra do produto: "se é invariante
-- que precisa valer mesmo quando o modelo erra, é código". Tinta não clareia
-- tinta; escurecer cabelo descolorido sem pré-pigmentar entrega cor esverdeada
-- que some na segunda lavagem; clarear até 8 e não matizar entrega laranja.
-- Nenhuma dessas três pode depender de o modelo lembrar. Elas são conta, e
-- conta se faz aqui dentro.
--
-- O QUE ELE NÃO FAZ, e é de propósito: ele não promete tom. A política do
-- salão já diz que "o que determina o tom é a saúde dos fios" e que só o teste
-- de mecha responde. O plano diz o CAMINHO -- quantos níveis faltam, quais
-- etapas, quanto tempo, quanto a mais, se exige teste. Quem diz se chega é o
-- teste.
--
-- E ele é honesto sobre a própria origem: `aindaSugerido` lista os números que
-- saíram da minha sugestão porque o dono ainda não respondeu aquela pergunta.
-- Um plano que apresenta sugestão minha como decisão do William é pior que
-- plano nenhum, porque ninguém desconfia dele.

create or replace function app.color_plan(
  p_tenant_id     uuid,
  p_from_level    smallint,
  p_current_state text,      -- VIRGEM | COLORIDO | DESCOLORIDO
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
  v_fundo     text;
  v_lift      integer;
  v_valores   jsonb := '{}'::jsonb;   -- key -> {valor, respondido}
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
  -- cliente: tinta não clareia tinta. Cabelo já colorido não sobe de tom com
  -- coloração, por menor que seja o clareamento pedido.
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

  -- ---- Pré-pigmentação ----------------------------------------------------
  -- Cabelo descolorido está vazio de pigmento quente. Escurecer por cima disso
  -- sem repor o fundo entrega cor acinzentada/esverdeada que sai na segunda
  -- lavagem. Vale também para ir a ruivo: vermelho não fixa em fio vazio.
  if p_current_state = 'DESCOLORIDO' and (v_lift < 0 or coalesce(v_familia.needs_warm_base, false)) then
    v_prepig := true;
    v_etapas := v_etapas || jsonb_build_object(
      'etapa', 'PRE_PIGMENTACAO',
      'porque', case when v_lift < 0
                  then 'O cabelo está descolorido e vai escurecer: sem repor o fundo, a cor não fixa e esverdeia.'
                  else 'O cabelo está descolorido e o tom pedido é quente: sem repor o fundo, o vermelho não segura.' end);
  end if;

  -- ---- Matização ----------------------------------------------------------
  -- Só depois de clarear, e não quando a família VIVE do fundo quente: em
  -- ruivo e acobreado, matizar é tirar justamente o que ia sustentar a cor.
  if v_descolore and not coalesce(v_familia.needs_warm_base, false) then
    v_matiza := true;
    v_etapas := v_etapas || jsonb_build_object(
      'etapa', 'MATIZACAO',
      'porque', format('Clareando até %s aparece fundo %s, e é ele que a matização neutraliza.', p_to_level, v_fundo));
  end if;

  -- ---- Teste de mecha -----------------------------------------------------
  v_usados := v_usados || 'TESTE_A_PARTIR_DE'::text;
  if v_lift >= (v_valores->'TESTE_A_PARTIR_DE'->>'valor')::numeric then
    v_teste := true;
  end if;
  if v_descolore then v_teste := true; end if;
  if p_has_chemistry then
    v_usados := v_usados || 'QUIMICA_EXIGE_TESTE'::text;
    if (v_valores->'QUIMICA_EXIGE_TESTE'->>'valor')::numeric = 1 then v_teste := true; end if;
  end if;

  -- ---- Tempo e preço ------------------------------------------------------
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

  -- ---- Avisos -------------------------------------------------------------
  -- Responde ao "como o agente vai saber que tal tom se encaixa em iluminado":
  -- a faixa é do salão, e pedir fora dela é um aviso, não uma etapa.
  if v_familia.id is not null and v_familia.min_level is not null
     and p_to_level not between v_familia.min_level and v_familia.max_level then
    v_avisos := v_avisos || format(
      'O tom %s está fora da faixa que este salão chama de %s (%s a %s).',
      p_to_level, v_familia.name, v_familia.min_level, v_familia.max_level);
  end if;
  if v_familia.id is not null and v_familia.answered_at is null then
    v_avisos := v_avisos || format('A faixa da família %s ainda é sugestão do sistema, o dono não confirmou.', v_familia.name);
  end if;

  -- Dos valores que ESTE plano usou, quais ainda são sugestão minha.
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

revoke all on function app.color_plan(uuid, smallint, text, smallint, uuid, boolean)
  from public, anon, authenticated;
grant execute on function app.color_plan(uuid, smallint, text, smallint, uuid, boolean)
  to service_role;

comment on function app.color_plan(uuid, smallint, text, smallint, uuid, boolean) is
  'O caminho do cabelo de hoje ate o tom pedido: quais etapas, quanto tempo e preco a mais, e se exige teste de mecha. Nao promete tom -- quem responde ate onde o fio chega e o teste. aindaSugerido lista os numeros que sairam de sugestao do sistema porque o dono nao respondeu aquela pergunta.';
