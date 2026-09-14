-- CLIENTE NOVA QUE JA CHEGA PERGUNTANDO PRECO CONTINUA SENDO CLIENTE NOVA.
--
-- Teste de 14/09, ficha zerada de proposito. A cliente escreveu "Boa tarde" e
-- "Gostaria de saber valor de luzes?". O agente respondeu:
--
--   "Oi, boa tarde! Tudo bem?"
--   "Qual o valor... o valor fica a partir de R$ 430,00, incluso hidratacao..."
--   "Realizamos o teste de mechas e dando tudo certo fazemos no mesmo dia"
--
-- Nao perguntou o nome dela. Nao pediu foto do cabelo. Nao pediu a referencia.
-- Nao ofereceu horario. Para uma cliente que nunca falou com o salao, isso e
-- um folheto, nao um atendimento.
--
-- O contexto estava CERTO: isKnown false, cinco pendencias na lista, nome
-- vazio. Ou seja, o agente tinha tudo para receber direito e nao recebeu. Dois
-- motivos, e os dois sao meus:
--
-- 1. O NOME NUNCA ESTEVE NA LISTA. `client_profile_missing` monta as
--    pendencias do cabelo -- foto, quimica, coloracao, tom, comprimento -- e o
--    nome nao esta la. O nome era tratado so pela regra de prompt da cliente
--    nova, que vale quando ela ainda nao disse o que quer. Quando ela ja chega
--    dizendo o que quer, aquele caminho nao se aplica e o nome nunca e pedido.
--    A pessoa vira "voce" pelo resto da conversa.
--
--    Aqui o nome entra na lista, na frente de tudo, e passa a ser tratado pela
--    mesma maquina que ja funciona para o resto. So entra quando o WhatsApp
--    tambem nao trouxe o nome: perguntar o nome de quem ja aparece
--    identificado e o oposto de atender bem.
--
-- 2. A REGRA DE PRECO QUE EU SUBI HOJE PASSOU POR CIMA DA PERGUNTA. Ela manda
--    responder o valor na hora, sem rodeio -- e esta certa. So que o modelo
--    leu "responda o preco" como "responda SO o preco" e abandonou a
--    pendencia. Responder o preco e a pergunta que falta cabem na mesma leva,
--    e e assim que uma recepcionista faz.

-- 1. O NOME ENTRA NA LISTA DE PENDENCIAS.
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
  -- O nome pode vir de dois lugares: a ficha, ou o proprio WhatsApp dela.
  -- So falta quando nenhum dos dois tem.
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
          coalesce((select coalesce(has_chemistry, false) and chemistry_formol is null from p), false)),
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

revoke all on function app.client_profile_missing(uuid, uuid) from public, anon, authenticated;
grant execute on function app.client_profile_missing(uuid, uuid) to service_role;

-- 2. RESPONDER O PRECO NAO DISPENSA A PERGUNTA QUE FALTA.
update app.agent_prompt_blocks
   set body = body || E'\nE responder o valor NÃO te dispensa do resto. Se a ficha dela ainda tem pendência, o valor e a pergunta que falta vão na MESMA leva: o valor primeiro, a pergunta logo depois. Quem chega perguntando preço continua sendo uma cliente que você ainda não conhece.'
 where code = 'OFICIO_PRECO_NA_HORA'
   and body not like '%NÃO te dispensa do resto%';
