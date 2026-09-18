create or replace function public.site_answer_owner_question(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_question_id uuid,
  target_answer text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_n integer;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if target_answer is null or length(trim(target_answer)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_ANSWER');
  end if;

  update app.agent_owner_questions
     set status = 'ANSWERED',
         answer = left(trim(target_answer), 2000),
         answered_by_email = target_email,
         answered_at = statement_timestamp()
   where id = target_question_id
     and tenant_id = target_tenant_id
     and status = 'PENDING';

  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'QUESTION_NOT_PENDING');
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_answer_owner_question(text, text, uuid, uuid, text) to service_role;

create or replace function public.site_dismiss_owner_question(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_question_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  update app.agent_owner_questions
     set status = 'DISMISSED', answered_by_email = target_email, answered_at = statement_timestamp()
   where id = target_question_id and tenant_id = target_tenant_id and status = 'PENDING';

  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_dismiss_owner_question(text, text, uuid, uuid) to service_role;