-- "ANO PASSADO" VIRA DATA.
--
-- 01/10, DEV: a Marina disse "já fiz luzes aí ano passado" e depois "faz 1
-- ano mais ou menos"; a atendente perguntou duas vezes "faz quanto tempo?".
-- Causa: app.periodo_para_data devolvia null para "ano passado", a ficha
-- descartava a resposta e a pergunta continuava pendente. A matriz de 30
-- jeitos de falar achou mais: número por extenso ("dois anos", "seis
-- meses"), "meio ano", "mês passado", "semana passada", "ontem", "esse ano",
-- mês pelo nome ("em março", "dezembro do ano passado") e "um ano e meio"
-- virando 1 ano.
--
-- Data aproximada é o certo aqui: ela fala aproximado e a ficha guarda as
-- palavras dela nas notas. "Faz tempo", "sei lá" e "nunca" continuam sem data.
-- Sem drop: a função antiga é usada o tempo todo pela ficha; ela passa a chamar
-- esta, que recebe "hoje" para poder ser testada com data fixa.
create or replace function app.periodo_para_data_em(p_texto text, p_hoje date)
 returns date
 language plpgsql
 stable
 set search_path to ''
as $function$
declare
  v text := ' ' || translate(lower(trim(coalesce(p_texto, ''))),
                             'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc') || ' ';
  v_num numeric;
  v_mes int;
  v_meses text[] := array['janeiro','fevereiro','marco','abril','maio','junho','julho',
                          'agosto','setembro','outubro','novembro','dezembro'];
  v_ano int := extract(year from p_hoje)::int;
  i int;
begin
  if v ~ '\m(nunca|sei la|nao sei|nao lembro|faz tempo|muito tempo)\M' and v !~ '\d' then
    return null;
  end if;

  -- Palavras soltas.
  if v ~ '\manteontem\M' then return p_hoje - 2; end if;
  if v ~ '\montem\M' then return p_hoje - 1; end if;
  if v ~ '\mhoje\M' then return p_hoje; end if;
  if v ~ '\msemana passada\M' then return p_hoje - 7; end if;
  if v ~ '\mmes passado\M' then return (p_hoje - interval '1 month')::date; end if;

  -- Mês pelo nome: "em março", "dezembro do ano passado".
  for i in 1..12 loop
    if v ~ ('\m' || v_meses[i] || '\M') then
      v_mes := i;
      exit;
    end if;
  end loop;
  if v_mes is not null then
    if v ~ '\mano passado\M' or v_mes > extract(month from p_hoje)::int then
      return make_date(v_ano - 1, v_mes, 15);
    end if;
    return least(make_date(v_ano, v_mes, 15), p_hoje);
  end if;

  if v ~ '\m(esse|este) ano\M' or v ~ '\mcomeco do ano\M' then
    return make_date(v_ano, 1, 1) + ((p_hoje - make_date(v_ano, 1, 1)) / 2);
  end if;

  -- Número: dígito ou por extenso.
  v_num := replace((regexp_match(v, '(\d+(?:[.,]\d+)?)'))[1], ',', '.')::numeric;
  if v_num is null then
    v_num := case
      when v ~ '\m(um|uma)\M' then 1
      when v ~ '\m(dois|duas)\M' then 2
      when v ~ '\mtres\M' then 3
      when v ~ '\mquatro\M' then 4
      when v ~ '\mcinco\M' then 5
      when v ~ '\mseis\M' then 6
      when v ~ '\msete\M' then 7
      when v ~ '\moito\M' then 8
      when v ~ '\mnove\M' then 9
      when v ~ '\mdez\M' then 10
      when v ~ '\monze\M' then 11
      when v ~ '\mdoze\M' then 12
      when v ~ '\mquinze\M' then 15
      when v ~ '\mvinte\M' then 20
      when v ~ '\mmeio ano\M' then 0.5
      else null end;
  end if;

  if v ~ '\mano passado\M' and v !~ '\manos?\M.*\manos?\M' and v_num is null then
    return (p_hoje - interval '1 year')::date;
  end if;
  if v_num is null then
    return null;
  end if;

  -- "um ano e meio", "2 anos e meio": mais seis meses.
  if v ~ '\manos?\M' then
    return (p_hoje - make_interval(months => (v_num * 12)::int
                                     + case when v ~ '\me meio\M' then 6 else 0 end))::date;
  end if;
  if v ~ '\m(mes|meses)\M' then
    return (p_hoje - make_interval(months => v_num::int))::date
           - case when v ~ '\me meio\M' then 15 else 0 end;
  end if;
  if v ~ '\msemanas?\M' then return p_hoje - (v_num * 7)::int; end if;
  if v ~ '\mdias?\M' then return p_hoje - v_num::int; end if;
  return null;
end;
$function$;

create or replace function app.periodo_para_data(p_texto text)
 returns date
 language sql
 stable
 set search_path to ''
as $function$ select app.periodo_para_data_em(p_texto, current_date); $function$;

revoke all on function app.periodo_para_data_em(text, date) from public, anon, authenticated;