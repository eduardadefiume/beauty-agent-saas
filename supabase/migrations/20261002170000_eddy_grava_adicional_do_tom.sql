-- O EDDY GRAVA O ADICIONAL DO TOM.
--
-- 02/10, DEV, William-robô, por áudio: "o platinado eu cobro mais cem reais
-- porque demora mais e gasta mais produto, o resto é o preço normal das
-- luzes". O adicional por tom (tone_families.extra_price_minor e
-- extra_minutes) é o que app.color_plan soma no orçamento de cor da
-- atendente -- e só o site conseguia gravar. O Eddy guardou como regra em
-- texto e disse "anotei"; o orçamento continuaria sem os R$ 100.
--
-- O dono fala do jeito dele ("loiro mel", "perolado", "morena iluminada"); a
-- função leva para o tom do sistema. O mais específico ganha: "loiro
-- platinado" é Platinado, não Loiro. Vale na hora (tom não passa pelo
-- rascunho, como no site). 0 = sem adicional.

create or replace function app.tom_do_que_o_dono_disse(p_tenant_id uuid, p_tom text)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  with t as (select ' ' || translate(lower(coalesce(p_tom, '')), 'áàâãéêíóôõúç', 'aaaaeeiooouc') || ' ' as x),
  codigo as (
    select case
      when x ~ '\m(platin\w*|gelo|cinza|acinzentad\w*|branco)\M' then 'PLATINADO'
      when x ~ '\m(ilumin\w*|balaiag\w*|balayage|ombre)\M' then 'ILUMINADO'
      when x ~ '\m(ruiv\w*|cobre|acobread\w*|vermelh\w*|marsala)\M' then 'RUIVO'
      when x ~ '\m(chocolate|cafe|marrom)\M' then 'CHOCOLATE'
      when x ~ '\m(loir\w*|lour\w*|perol\w*|mel|dourad\w*|bege|caramel\w*)\M' then 'LOIRO'
      when x ~ '\m(castanh\w*)\M' then 'CASTANHO'
      when x ~ '\m(pret\w*|azulad\w*)\M' then 'PRETO'
    end as c
    from t
  )
  select f.id
    from app.tone_families f, codigo, t
   where f.tenant_id = p_tenant_id and f.status = 'ACTIVE'
     and (f.product_code = codigo.c
          or translate(lower(f.name), 'áàâãéêíóôõúç', 'aaaaeeiooouc') = trim(t.x))
   order by (f.product_code = codigo.c) desc
   limit 1;
$$;
revoke all on function app.tom_do_que_o_dono_disse(uuid, text) from public, anon, authenticated;

create or replace function app.eddy_definir_adicional_do_tom(
  p_tenant_id uuid, p_tom text, p_reais numeric, p_minutos integer default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id uuid;
  v_nome text;
begin
  if p_reais is not null and p_reais < 0 or p_minutos is not null and (p_minutos < 0 or p_minutos > 600) then
    return jsonb_build_object('ok', false, 'reason', 'VALOR_INVALIDO');
  end if;
  v_id := app.tom_do_que_o_dono_disse(p_tenant_id, p_tom);
  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'TOM_NAO_EXISTE',
      'tons', (select to_jsonb(array_agg(f.name order by f.position)) from app.tone_families f
                where f.tenant_id = p_tenant_id and f.status = 'ACTIVE'));
  end if;
  update app.tone_families f
     set extra_price_minor = case when p_reais is null then f.extra_price_minor
                                  else nullif(round(p_reais * 100)::integer, 0) end,
         extra_minutes = case when p_minutos is null then f.extra_minutes else nullif(p_minutos, 0) end,
         updated_at = statement_timestamp()
   where f.id = v_id
  returning f.name into v_nome;
  return jsonb_build_object('ok', true, 'tom', v_nome,
    'tons', (select jsonb_agg(jsonb_build_object('tom', f.name,
               'adicional', case when f.extra_price_minor is null then 'sem adicional'
                                 else 'R$ ' || app.agenda_reais_curto(f.extra_price_minor) end,
               'minutosAMais', f.extra_minutes) order by f.position)
               from app.tone_families f where f.tenant_id = p_tenant_id and f.status = 'ACTIVE'));
end;
$$;
revoke all on function app.eddy_definir_adicional_do_tom(uuid, text, numeric, integer) from public, anon, authenticated;

create or replace function public.eddy_definir_adicional_do_tom(
  p_tenant_id uuid, p_tom text, p_reais numeric, p_minutos integer default null)
returns jsonb
language sql
security definer
set search_path to ''
as $$ select app.eddy_definir_adicional_do_tom(p_tenant_id, p_tom, p_reais, p_minutos); $$;
revoke all on function public.eddy_definir_adicional_do_tom(uuid, text, numeric, integer) from public, anon, authenticated;
grant execute on function public.eddy_definir_adicional_do_tom(uuid, text, numeric, integer) to service_role;
