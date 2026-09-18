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