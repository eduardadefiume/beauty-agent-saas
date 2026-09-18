-- O agente so conhece a conversa. Quem sabe qual ficha e daquela conversa e o
-- banco. Assim o id da ficha nunca precisa entrar no contexto do modelo, e nao
-- existe caminho para ele escrever na ficha de outra pessoa.
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
  v_profile uuid;
begin
  select c.tenant_id, p.id
    into v_tenant, v_profile
    from app.crm_conversations c
    join app.client_profiles p
      on p.tenant_id = c.tenant_id and p.contact_id = c.contact_id
   where c.id = p_conversation_id;

  if v_profile is null then
    return jsonb_build_object('ok', false, 'reason', 'PROFILE_NOT_FOUND');
  end if;

  return public.record_client_profile_facts(v_tenant, v_profile, p_facts);
end;
$function$;

revoke all on function public.record_client_facts_for_conversation(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_client_facts_for_conversation(uuid, jsonb) to service_role;