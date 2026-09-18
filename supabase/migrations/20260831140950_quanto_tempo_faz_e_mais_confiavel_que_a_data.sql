-- "Faz uns 2 anos" e mais confiavel que uma data calculada por um modelo.
--
-- A cliente disse "faz uns 2 anos" e o agente gravou que ela tem quimica sem
-- gravar quando. A pendencia continuou aberta e a diretriz do turno mandou
-- perguntar de novo o que ela ja tinha respondido.
--
-- Parte do conserto e comportamento, mas parte e desenho: pedir para um modelo
-- transformar "uns 2 anos" numa data ISO e uma conta que ele pode errar em
-- silencio. Agora ele pode mandar o periodo como a cliente falou, e a conta
-- acontece aqui.
--
-- A data fica sempre no COMECO do periodo declarado (hoje menos o intervalo),
-- e o texto original vai para a observacao: "uns 2 anos" e aproximacao da
-- cliente, nao registro exato, e a ficha nao pode fingir precisao que ninguem
-- tem.
create or replace function app.periodo_para_data(p_texto text)
returns date
language sql
immutable
set search_path to ''
as $function$
  with t as (select lower(trim(coalesce(p_texto, ''))) as v),
  n as (
    select v,
           -- Primeiro numero que aparecer. "uns 2 anos" -> 2; "um ano" -> 1.
           coalesce(
             nullif((regexp_match(v, '(\d+)'))[1], '')::numeric,
             case when v like '%um %' or v like '%uma %' then 1 else null end
           ) as qtd
      from t
  )
  select case
           when qtd is null then null
           when v like '%ano%'    then (current_date - (qtd * interval '1 year'))::date
           when v like '%mes%' or v like '%mês%' or v like '%meses%'
                                 then (current_date - (qtd * interval '1 month'))::date
           when v like '%semana%' then (current_date - (qtd * interval '1 week'))::date
           when v like '%dia%'    then (current_date - (qtd * interval '1 day'))::date
           else null
         end
    from n;
$function$;

comment on function app.periodo_para_data(text) is
  'Converte "uns 2 anos", "6 meses", "3 semanas" em data aproximada. Existe para o agente nao precisar fazer conta de calendario, que e onde modelo erra calado.';

create or replace function public.record_client_profile_facts(
  p_tenant_id  uuid,
  p_profile_id uuid,
  p_facts      jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_compr_txt  text := nullif(trim(coalesce(p_facts->>'comprimento', '')), '');
  v_compr_id   uuid;
  v_formol     text := upper(nullif(trim(coalesce(p_facts->>'quimicaFormol', '')), ''));
  v_nome       text := nullif(trim(coalesce(p_facts->>'nome', '')), '');
  v_quim_txt   text := nullif(trim(coalesce(p_facts->>'quimicaHaQuantoTempo', '')), '');
  v_cor_txt    text := nullif(trim(coalesce(p_facts->>'coloracaoHaQuantoTempo', '')), '');
  v_quim_data  date := coalesce((nullif(p_facts->>'quimicaQuando',''))::date,
                                app.periodo_para_data(v_quim_txt));
  v_cor_data   date := coalesce((nullif(p_facts->>'coloracaoQuando',''))::date,
                                app.periodo_para_data(v_cor_txt));
  v_ignorados  text[] := '{}';
  v_linha      app.client_profiles;
  v_falta      jsonb;
begin
  if v_formol is not null and v_formol not in ('COM_FORMOL', 'SEM_FORMOL', 'NAO_SABE') then
    v_ignorados := v_ignorados || 'quimicaFormol';
    v_formol := null;
  end if;

  if v_quim_txt is not null and v_quim_data is null then
    v_ignorados := v_ignorados || 'quimicaHaQuantoTempo';
  end if;
  if v_cor_txt is not null and v_cor_data is null then
    v_ignorados := v_ignorados || 'coloracaoHaQuantoTempo';
  end if;

  if v_compr_txt is not null then
    select o.id
      into v_compr_id
      from app.knowledge_options o
      join app.knowledge_dimensions d
        on d.id = o.dimension_id and d.tenant_id = o.tenant_id
     where o.tenant_id = p_tenant_id
       and o.status = 'ACTIVE'
       and d.status = 'ACTIVE'
       and lower(d.name) like 'compriment%'
       and lower(o.label) = lower(v_compr_txt)
     limit 1;

    if v_compr_id is null then
      v_ignorados := v_ignorados || 'comprimento';
    end if;
  end if;

  update app.client_profiles p
     set preferred_name = coalesce(v_nome, p.preferred_name),
         length_option_id = coalesce(v_compr_id, p.length_option_id),

         has_chemistry = coalesce((p_facts->>'temQuimica')::boolean, p.has_chemistry),
         chemistry_kind = coalesce(nullif(trim(coalesce(p_facts->>'quimicaQual','')), ''),
                                   p.chemistry_kind),
         chemistry_last_at = coalesce(v_quim_data, p.chemistry_last_at),
         chemistry_formol = coalesce(v_formol, p.chemistry_formol),

         has_color = coalesce((p_facts->>'temColoracao')::boolean, p.has_color),
         color_last_at = coalesce(v_cor_data, p.color_last_at),
         tone_wanted = coalesce(nullif(trim(coalesce(p_facts->>'tomQueQuer','')), ''),
                                p.tone_wanted),

         -- O que ela falou fica registrado como ela falou. A data e deducao.
         notes = case
                   when nullif(trim(coalesce(p_facts->>'observacao','')), '') is null
                        and v_quim_txt is null and v_cor_txt is null then p.notes
                   else left(
                     concat_ws(E'\n',
                       p.notes,
                       nullif(trim(coalesce(p_facts->>'observacao','')), ''),
                       case when v_quim_txt is not null
                            then 'Cliente disse sobre a última química: ' || v_quim_txt end,
                       case when v_cor_txt is not null
                            then 'Cliente disse sobre a última coloração: ' || v_cor_txt end
                     ), 4000)
                 end,

         updated_at = statement_timestamp()
   where p.tenant_id = p_tenant_id
     and p.id = p_profile_id
  returning * into v_linha;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'PROFILE_NOT_FOUND');
  end if;

  v_falta := app.client_profile_missing(p_tenant_id, p_profile_id);

  if v_falta = '[]'::jsonb and v_linha.status = 'PRE_CADASTRO' then
    update app.client_profiles
       set status = 'COMPLETO', updated_at = statement_timestamp()
     where tenant_id = p_tenant_id and id = p_profile_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'ignorados', to_jsonb(v_ignorados),
    'aindaFalta', v_falta
  );
end;
$function$;

revoke all on function public.record_client_profile_facts(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_client_profile_facts(uuid, uuid, jsonb) to service_role;