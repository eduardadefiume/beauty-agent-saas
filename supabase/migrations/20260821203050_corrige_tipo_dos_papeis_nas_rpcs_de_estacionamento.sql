-- private.require_site_tenant recebe app.tenant_role[], não text[]. O literal
-- array['OWNER','OPERATOR'] vira text[] e não casa com a assinatura.
create or replace function public.site_agent_parked_conversations(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_limit           integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_limite integer := least(greatest(coalesce(target_limit, 50), 1), 200);
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'conversationId', f.conversation_id,
             'contactName',    ct.display_name,
             'whatsapp',       ch.address_normalized,
             'failures',       f.failures,
             'lastError',      f.last_error,
             'parkedAt',       f.parked_at,
             'lastInboundAt',  cv.last_inbound_at
           ) order by f.parked_at desc)
      from app.agent_conversation_failures f
      join app.crm_conversations cv
        on cv.tenant_id = f.tenant_id and cv.id = f.conversation_id
      join app.crm_contacts ct
        on ct.tenant_id = cv.tenant_id and ct.id = cv.contact_id
      left join app.crm_contact_channels ch
        on ch.tenant_id = cv.tenant_id and ch.contact_id = cv.contact_id and ch.provider = 'WHATSAPP'
     where f.tenant_id = target_tenant_id
       and f.parked_at is not null
     limit v_limite
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.site_agent_parked_conversations(text, text, uuid, integer) to service_role;

create or replace function public.site_resume_parked_conversation(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_conversation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  delete from app.agent_conversation_failures
   where tenant_id = target_tenant_id and conversation_id = target_conversation_id;

  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_resume_parked_conversation(text, text, uuid, uuid) to service_role;