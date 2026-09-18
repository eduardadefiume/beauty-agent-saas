create or replace function app.coexistence_absorb_contacts(
  p_tenant_id uuid,
  p_value     jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_item     jsonb;
  v_fone     text;
  v_nome     text;
  v_contato  uuid;
  v_novos    integer := 0;
  v_renomeados integer := 0;
  v_unidade  uuid;
begin
  select u.id into v_unidade from app.units u where u.tenant_id = p_tenant_id
   order by u.created_at limit 1;

  for v_item in select value from jsonb_array_elements(
                  case when jsonb_typeof(p_value->'state_sync') = 'array'
                       then p_value->'state_sync' else '[]'::jsonb end)
  loop
    continue when coalesce(v_item->>'type', '') <> 'contact';

    v_fone := regexp_replace(
      coalesce(v_item->'contact'->>'phone_number', ''), '[^0-9]', '', 'g');
    continue when length(v_fone) < 8;

    v_nome := nullif(trim(coalesce(
      v_item->'contact'->>'full_name', v_item->'contact'->>'first_name', '')), '');

    v_contato := null;
    select c.contact_id into v_contato
      from app.crm_contact_channels c
     where c.tenant_id = p_tenant_id
       and right(regexp_replace(c.address_normalized, '[^0-9]', '', 'g'), 8) = right(v_fone, 8)
     limit 1;

    if v_contato is null then
      insert into app.crm_contacts (tenant_id, unit_id, display_name, status)
      values (p_tenant_id, v_unidade, coalesce(v_nome, v_fone), 'ACTIVE')
      returning id into v_contato;

      insert into app.crm_contact_channels
        (tenant_id, contact_id, provider, address_normalized, is_primary)
      values (p_tenant_id, v_contato, 'WHATSAPP', v_fone, true)
      on conflict do nothing;

      v_novos := v_novos + 1;

    elsif v_nome is not null then
      -- So troca quando o nome de hoje e um numero. Nome escrito por uma
      -- pessoa nao e sobrescrito por sincronizacao.
      update app.crm_contacts c
         set display_name = v_nome, updated_at = statement_timestamp()
       where c.id = v_contato
         and (c.display_name is null or c.display_name ~ '^[+0-9 ()-]+$')
         and c.display_name is distinct from v_nome;
      if found then v_renomeados := v_renomeados + 1; end if;
    end if;

    -- A conversa do arquivo que estava sem cliente amarrada acha a dona agora.
    update app.wa_archives a
       set contact_id = v_contato, updated_at = statement_timestamp()
     where a.tenant_id = p_tenant_id and a.contact_id is null
       and right(regexp_replace(coalesce(a.phone_digits, ''), '[^0-9]', '', 'g'), 8) = right(v_fone, 8);
  end loop;

  return jsonb_build_object('novos', v_novos, 'renomeados', v_renomeados);
end;
$function$;

revoke all on function app.coexistence_absorb_contacts(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.coexistence_absorb_contacts(uuid, jsonb) to service_role;
