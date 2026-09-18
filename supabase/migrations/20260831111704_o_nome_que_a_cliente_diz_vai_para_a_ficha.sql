-- Cliente nova que ainda nao tem nome no contato diz o nome na conversa. Sem
-- este campo, ela diria o nome e o sistema esqueceria no minuto seguinte.
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
  v_ignorados  text[] := '{}';
  v_linha      app.client_profiles;
  v_falta      jsonb;
begin
  if v_formol is not null and v_formol not in ('COM_FORMOL', 'SEM_FORMOL', 'NAO_SABE') then
    v_ignorados := v_ignorados || 'quimicaFormol';
    v_formol := null;
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
         chemistry_last_at = coalesce((nullif(p_facts->>'quimicaQuando',''))::date,
                                      p.chemistry_last_at),
         chemistry_formol = coalesce(v_formol, p.chemistry_formol),

         has_color = coalesce((p_facts->>'temColoracao')::boolean, p.has_color),
         color_last_at = coalesce((nullif(p_facts->>'coloracaoQuando',''))::date,
                                  p.color_last_at),
         tone_wanted = coalesce(nullif(trim(coalesce(p_facts->>'tomQueQuer','')), ''),
                                p.tone_wanted),

         notes = case
                   when nullif(trim(coalesce(p_facts->>'observacao','')), '') is null then p.notes
                   when p.notes is null then trim(p_facts->>'observacao')
                   else left(p.notes || E'\n' || trim(p_facts->>'observacao'), 4000)
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