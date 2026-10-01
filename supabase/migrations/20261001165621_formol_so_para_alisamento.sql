-- Formol é pergunta de alisamento. 01/10, DEV: a Marina disse "já fiz luzes"
-- e ouviu "essa química tinha formol?". Luzes, mechas, descoloração e
-- coloração não levam formol; perguntar isso mostra que a atendente não sabe
-- do que está falando. Química sem nome continua com a pergunta (lado seguro).
-- Mesma regra de supabase/functions/whatsapp-agent/ficha-dita.ts (quimicaPodeTerFormol).
create or replace function app.quimica_pode_ter_formol(p_qual text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select case
    when nullif(trim(coalesce(p_qual, '')), '') is null then true
    when translate(lower(p_qual), 'áàâãéêíóôõúç', 'aaaaeeiooouc')
         ~ '(progressiva|alisament|selante|botox|relaxamento|definitiva|queratin|keratin|formol|realinhamento|plastica|blindagem|escova (inteligente|marroquina|japonesa))'
      then true
    else translate(lower(p_qual), 'áàâãéêíóôõúç', 'aaaaeeiooouc')
         !~ '(luzes|mecha|descolor|platinad|iluminad|balaiagem|balayage|reflexo|ombre|tintura|coloracao|loir)'
  end;
$$;

revoke all on function app.quimica_pode_ter_formol(text) from public, anon, authenticated;

create or replace function app.client_profile_missing(p_tenant_id uuid, p_profile_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  with p as (
    select * from app.client_profiles
     where tenant_id = p_tenant_id and id = p_profile_id
  ),
  nome as (
    select coalesce(nullif(trim(coalesce((select preferred_name from p), '')), ''), '') = ''
       and coalesce(nullif(trim(coalesce(
             (select ct.display_name
                from app.crm_contacts ct
               where ct.id = (select contact_id from p)), '')), ''), '') = ''
           as falta
  ),
  tem_foto as (
    select exists (
             select 1 from app.client_photos f
              where f.tenant_id = p_tenant_id and f.profile_id = p_profile_id
                and f.kind = 'CABELO_ATUAL'
           )
           or coalesce((select hair_photo_seen_at > (statement_timestamp() - interval '120 days')
                          from p), false)
           as sim
  ),
  fixas as (
    select * from (values
      (0, 'NOME',             'Qual o seu nome?',
          coalesce((select falta from nome), true)),
      (1, 'FOTO_ATUAL',       'Manda uma foto do seu cabelo hoje, como ele está?',
          (select not coalesce(sim, false) from tem_foto)),
      (2, 'TEM_QUIMICA',      'Você já fez alguma química no cabelo?',
          coalesce((select has_chemistry is null from p), true)),
      (3, 'QUANDO_A_QUIMICA', 'Faz quanto tempo que você fez a última química?',
          coalesce((select coalesce(has_chemistry, false) and chemistry_last_at is null from p), false)),
      (4, 'QUIMICA_COM_FORMOL','Você sabe se essa química tinha formol?',
          coalesce((select coalesce(has_chemistry, false) and chemistry_formol is null
                           and app.quimica_pode_ter_formol(chemistry_kind) from p), false)),
      (5, 'TEM_COLORACAO',    'Seu cabelo é colorido ou tem tintura?',
          coalesce((select has_color is null from p), true)),
      (6, 'QUANDO_COLORIU',   'Faz quanto tempo que você coloriu?',
          coalesce((select coalesce(has_color, false) and color_last_at is null from p), false)),
      (7, 'TOM_QUE_QUER',     'Me manda uma foto do tom que você quer alcançar?',
          coalesce((select tone_wanted is null from p), true))
    ) as v(ordem, campo, pergunta, falta)
     where falta
  ),
  da_regua as (
    select 10 + d.position as ordem,
           'CLASSIFICACAO:' || d.id::text as campo,
           'Seu cabelo é ' || (
             select string_agg(lower(o.label), ' ou ' order by o.position)
               from app.knowledge_options o
              where o.dimension_id = d.id and o.status = 'ACTIVE'
           ) || '?' as pergunta
      from app.knowledge_dimensions d
     where d.tenant_id = p_tenant_id
       and d.status = 'ACTIVE'
       and exists (select 1 from app.knowledge_options o
                    where o.dimension_id = d.id and o.status = 'ACTIVE')
       and not exists (select 1 from app.client_classifications c
                        where c.profile_id = p_profile_id and c.dimension_id = d.id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'campo', campo, 'perguntaSugerida', pergunta
         ) order by ordem), '[]'::jsonb)
    from (select ordem, campo, pergunta from fixas
          union all
          select ordem, campo, pergunta from da_regua) tudo;
$function$;
