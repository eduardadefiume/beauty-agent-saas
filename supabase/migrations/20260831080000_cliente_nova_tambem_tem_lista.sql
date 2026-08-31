-- Cliente nova também tem lista do que falta.
--
-- Apagamos a conversa e a ficha de teste para o agente ver a Duda como uma
-- cliente que nunca falou com o salão. Aí apareceu o buraco: sem ficha,
-- `client_profile_missing` devolvia lista vazia, porque cada campo era
-- comparado contra uma linha que não existe e `null` não entra no `where`.
--
-- Com a lista vazia, a trava da investigação (que tira reservar_horario da mesa
-- enquanto faltar ficha) ficava DESLIGADA exatamente para quem mais precisa
-- dela: a pessoa de quem o salão não sabe absolutamente nada.
--
-- Sem ficha, tudo falta. É o que esta migração diz, campo por campo.
--
-- E vem junto o outro lado da mesma moeda: escrever na ficha de quem ainda não
-- tem ficha agora CRIA a ficha. Antes, a primeira coisa que o agente
-- descobrisse de uma cliente nova era jogada fora com PROFILE_NOT_FOUND.

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
          coalesce((select tone_wanted is null from p), true)),
      (8, 'COMPRIMENTO',
          coalesce((select 'Seu cabelo é ' || texto || '?' from comprimentos where texto is not null),
                   'Como é o comprimento do seu cabelo?'),
          coalesce((select length_option_id is null from p), true))
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

create or replace function public.record_client_facts_for_conversation(
  p_conversation_id uuid,
  p_facts           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tenant  uuid;
  v_contato uuid;
  v_nome    text;
  v_profile uuid;
begin
  select c.tenant_id, c.contact_id, ct.display_name
    into v_tenant, v_contato, v_nome
    from app.crm_conversations c
    join app.crm_contacts ct on ct.tenant_id = c.tenant_id and ct.id = c.contact_id
   where c.id = p_conversation_id;

  if v_tenant is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSATION_NOT_FOUND');
  end if;

  select p.id into v_profile
    from app.client_profiles p
   where p.tenant_id = v_tenant and p.contact_id = v_contato;

  if v_profile is null then
    insert into app.client_profiles (tenant_id, contact_id, preferred_name, status)
    values (v_tenant, v_contato, split_part(coalesce(nullif(trim(v_nome), ''), ''), ' ', 1),
            'PRE_CADASTRO')
    returning id into v_profile;
  end if;

  return public.record_client_profile_facts(v_tenant, v_profile, p_facts);
end;
$function$;

revoke all on function public.record_client_facts_for_conversation(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_client_facts_for_conversation(uuid, jsonb) to service_role;

-- O contexto manda a lista tambem quando nao ha ficha nenhuma.
do $do$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'build_agent_context';

  v_def := replace(
    v_def,
    'v_cliente := jsonb_build_object(''isKnown'', false);',
    'v_cliente := jsonb_build_object(''isKnown'', false, ''missing'', app.client_profile_missing(v_c.tenant_id, null));'
  );

  execute v_def;
end
$do$;
