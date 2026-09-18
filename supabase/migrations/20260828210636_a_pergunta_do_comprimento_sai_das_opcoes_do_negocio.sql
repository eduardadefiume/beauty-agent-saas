-- "Seu cabelo é curto, médio ou comprido?" era invencao minha. Este salao so
-- tem Curto e Longo cadastrados; oferecer "medio" e ensinar a cliente a dar uma
-- resposta que a ficha nao sabe guardar. A pergunta passa a ser montada com as
-- opcoes que o proprio negocio cadastrou, e vem junto a lista exata de rotulos
-- para o agente escrever de volta sem inventar.
create or replace function app.client_profile_missing(
  p_tenant_id  uuid,
  p_profile_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with p as (
    select * from app.client_profiles
     where tenant_id = p_tenant_id and id = p_profile_id
  ),
  comprimentos as (
    select coalesce(jsonb_agg(o.label order by o.position), '[]'::jsonb) as rotulos,
           string_agg(lower(o.label), ' ou ' order by o.position)        as texto
      from app.knowledge_options o
      join app.knowledge_dimensions d
        on d.id = o.dimension_id and d.tenant_id = o.tenant_id
     where o.tenant_id = p_tenant_id
       and o.status = 'ACTIVE' and d.status = 'ACTIVE'
       and lower(d.name) like 'compriment%'
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
  faltas as (
    select * from (values
      (1, 'FOTO_ATUAL',       'Manda uma foto do seu cabelo hoje, como ele está?',
          (select not coalesce(sim, false) from tem_foto)),
      (2, 'TEM_QUIMICA',      'Você já fez alguma química no cabelo?',
          (select has_chemistry is null from p)),
      (3, 'QUANDO_A_QUIMICA', 'Faz quanto tempo que você fez a última química?',
          (select coalesce(has_chemistry, false) and chemistry_last_at is null from p)),
      (4, 'QUIMICA_COM_FORMOL','Você sabe se essa química tinha formol?',
          (select coalesce(has_chemistry, false) and chemistry_formol is null from p)),
      (5, 'TEM_COLORACAO',    'Seu cabelo é colorido ou tem tintura?',
          (select has_color is null from p)),
      (6, 'QUANDO_COLORIU',   'Faz quanto tempo que você coloriu?',
          (select coalesce(has_color, false) and color_last_at is null from p)),
      (7, 'TOM_QUE_QUER',     'Me manda uma foto do tom que você quer alcançar?',
          (select tone_wanted is null from p)),
      (8, 'COMPRIMENTO',
          coalesce((select 'Seu cabelo é ' || texto || '?' from comprimentos where texto is not null),
                   'Como é o comprimento do seu cabelo?'),
          (select length_option_id is null from p))
    ) as v(ordem, campo, pergunta, falta)
  )
  select coalesce(jsonb_agg(
           case when campo = 'COMPRIMENTO'
                then jsonb_build_object('campo', campo, 'perguntaSugerida', pergunta,
                                        'rotulosValidos', (select rotulos from comprimentos))
                else jsonb_build_object('campo', campo, 'perguntaSugerida', pergunta)
           end order by ordem), '[]'::jsonb)
    from faltas where falta;
$function$;

revoke all on function app.client_profile_missing(uuid, uuid) from public, anon, authenticated;
grant execute on function app.client_profile_missing(uuid, uuid) to service_role;