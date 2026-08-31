-- O agente pediu "manda uma foto do seu cabelo hoje, como ele esta?". A
-- cliente mandou. Ele respondeu "Adorei a referencia, Eduarda!" e gravou a
-- descricao do cabelo DELA no campo do tom que ela QUER:
--
--   toneWanted = "Tom castanho medio com reflexos acobreados/mel nas pontas"
--
-- Isso e o cabelo atual dela, nao o objetivo. E o estrago nao parou ai: com
-- tone_wanted preenchido, a lista de pendencias esvaziou, o portao abriu e o
-- agente foi direto para preco e horario sem NUNCA pedir a foto de referencia.
-- Uma leitura errada de foto pulou uma etapa inteira do atendimento, em
-- silencio.
--
-- Ja existe regra de prompt sobre isso -- "foto de referencia e o que ela
-- quer, nao o que ela tem" -- e ela nao segurou. Entao vira invariante.
--
-- A TRAVA, e por que ela nao pega falso positivo: so bloqueia quando as duas
-- coisas valem ao mesmo tempo:
--
--   1) chegou uma FOTO nesta leva -- ou seja, alguma mensagem de midia da
--      cliente depois da ultima mensagem que o agente mandou; e
--   2) a ficha ainda nunca viu foto do cabelo atual dela.
--
-- Nessa combinacao, a foto que acabou de chegar so pode ser o cabelo dela --
-- e o "tom que ela quer" tirado dali esta errado por construcao. Quando ela
-- ESCREVE o que quer ("quero ficar loira") sem mandar foto, nada e bloqueado.
-- Quando ela manda a referencia depois, a foto do cabelo dela ja foi vista e
-- nada e bloqueado.
--
-- E "chegou foto nesta leva", e nao "a ultima mensagem e foto", porque no caso
-- real a cliente mandou a foto e logo depois escreveu "Esta assim". A ultima
-- mensagem era o texto; a foto estava uma linha acima. Olhar so a ultima
-- mensagem deixaria passar exatamente o caso que originou a trava.
--
-- O campo bloqueado volta para o agente na lista `ignorados`, entao ele sabe
-- que nao gravou e pode perguntar direito.
create or replace function public.record_client_facts_for_conversation(
  p_conversation_id uuid,
  p_facts           jsonb
) returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_tenant       uuid;
  v_contato      uuid;
  v_nome         text;
  v_profile      uuid;
  v_viu_cabelo   timestamptz;
  v_ultimo_envio timestamptz;
  v_foto_na_leva boolean;
  v_resposta     jsonb;
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

  select p.hair_photo_seen_at into v_viu_cabelo
    from app.client_profiles p where p.id = v_profile;

  select max(m.occurred_at)
    into v_ultimo_envio
    from app.crm_messages m
   where m.conversation_id = p_conversation_id
     and m.direction = 'OUTBOUND';

  select exists (
    select 1
      from app.crm_messages m
     where m.conversation_id = p_conversation_id
       and m.direction = 'INBOUND'
       and m.message_type = 'MEDIA'
       and (v_ultimo_envio is null or m.occurred_at > v_ultimo_envio)
  ) into v_foto_na_leva;

  if v_viu_cabelo is null
     and coalesce(v_foto_na_leva, false)
     and nullif(trim(coalesce(p_facts->>'tomQueQuer', '')), '') is not null then
    p_facts := p_facts - 'tomQueQuer';
    v_resposta := public.record_client_profile_facts(v_tenant, v_profile, p_facts);
    return jsonb_set(
      v_resposta,
      '{ignorados}',
      coalesce(v_resposta->'ignorados', '[]'::jsonb) || to_jsonb('tomQueQuer'::text)
    ) || jsonb_build_object(
      'atencao',
      'A foto que ela acabou de mandar é o cabelo DELA, não a referência: você ainda não tinha visto '
      || 'o cabelo atual dela. NÃO grave isso como tom desejado e NÃO diga que gostou da referência. '
      || 'Anote o que viu como o cabelo dela e peça, em outra mensagem, a foto do tom que ela quer alcançar.'
    );
  end if;

  return public.record_client_profile_facts(v_tenant, v_profile, p_facts);
end;
$$;

revoke all on function public.record_client_facts_for_conversation(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_client_facts_for_conversation(uuid, jsonb) to service_role;
