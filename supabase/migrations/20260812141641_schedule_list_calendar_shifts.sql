begin;

-- Ocupação vinda do Google/Outlook para o motor de agenda tratar como
-- bloqueio. Hoje a conexão é sempre por unidade (não existe ainda escolha
-- de "essa agenda é de qual profissional" na tela de conectar), então o
-- motor trata como bloqueio de TODA a equipe daquela unidade — igual uma
-- agenda compartilhada do salão. Quando a conexão por profissional
-- existir, esta RPC muda para devolver por membro, e a engine de agenda
-- (buildEligibleMembers) já está pronta para excluir só o profissional
-- certo, é só trocar o filtro aqui.
create function public.schedule_list_calendar_shifts(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'startMs', floor(extract(epoch from lower(s.time_range)) * 1000),
      'endMs', floor(extract(epoch from upper(s.time_range)) * 1000)
    ))
    from app.member_calendar_shifts s
    where s.tenant_id = target_tenant_id and s.unit_id = target_unit_id
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.schedule_list_calendar_shifts(text, text, uuid, uuid) to service_role;

commit;
