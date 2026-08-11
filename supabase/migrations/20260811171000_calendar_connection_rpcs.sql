begin;

-- Grava (cria ou atualiza) uma conexão de calendário externo depois da
-- troca de código OAuth. Chamada pela rota /auth/google-calendar/callback
-- do Next.js, que já fez a troca com o Google server-to-server (o client
-- secret nunca sai do servidor). O token em si só é lido por quem tem
-- service_role — nenhuma RPC devolve o token pra fora.
create function public.site_save_calendar_connection(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_provider text,
  target_member_name text,
  target_external_account_email text,
  target_calendar_id text,
  target_access_token text,
  target_refresh_token text,
  target_token_expires_at timestamptz,
  target_scope text
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  target_unit_id uuid;
  new_id uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if target_provider not in ('GOOGLE', 'MICROSOFT') then
    raise exception using errcode = '22023', message = 'INVALID_PROVIDER';
  end if;

  select u.id into target_unit_id from app.units u where u.tenant_id = target_tenant_id limit 1;
  if target_unit_id is null then
    raise exception using errcode = 'P0002', message = 'UNIT_NOT_FOUND';
  end if;

  insert into app.calendar_connections (
    tenant_id, unit_id, member_name, provider, external_account_email, calendar_id,
    access_token, refresh_token, token_expires_at, scope, status, last_error
  ) values (
    target_tenant_id, target_unit_id, target_member_name, target_provider, target_external_account_email,
    coalesce(nullif(target_calendar_id, ''), 'primary'),
    target_access_token, target_refresh_token, target_token_expires_at, target_scope, 'ACTIVE', null
  )
  on conflict (tenant_id, unit_id, provider, member_name) do update
    set external_account_email = excluded.external_account_email,
        calendar_id = excluded.calendar_id,
        access_token = excluded.access_token,
        refresh_token = coalesce(excluded.refresh_token, app.calendar_connections.refresh_token),
        token_expires_at = excluded.token_expires_at,
        scope = excluded.scope,
        status = 'ACTIVE',
        last_error = null,
        updated_at = statement_timestamp()
  returning id into new_id;

  return jsonb_build_object('connectionId', new_id, 'status', 'ACTIVE');
end;
$function$;

grant execute on function public.site_save_calendar_connection(
  text, text, uuid, text, text, text, text, text, text, timestamptz, text
) to service_role;

-- Status das conexões, sem token nenhum — é o que a tela mostra.
create function public.site_list_calendar_connections(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid
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
      'id', c.id,
      'provider', c.provider,
      'memberName', c.member_name,
      'externalAccountEmail', c.external_account_email,
      'status', c.status,
      'lastSyncedAt', c.last_synced_at,
      'lastError', c.last_error,
      'createdAt', c.created_at
    ) order by c.created_at)
    from app.calendar_connections c
    where c.tenant_id = target_tenant_id
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.site_list_calendar_connections(text, text, uuid) to service_role;

-- Desconecta: apaga o token (não guarda revogado à toa) e marca o status.
create function public.site_disconnect_calendar_connection(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_connection_id uuid
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  update app.calendar_connections
     set status = 'DISCONNECTED',
         access_token = null,
         refresh_token = null,
         token_expires_at = null,
         updated_at = statement_timestamp()
   where id = target_connection_id and tenant_id = target_tenant_id;

  delete from app.member_calendar_shifts
   where connection_id = target_connection_id and tenant_id = target_tenant_id;

  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_disconnect_calendar_connection(text, text, uuid, uuid) to service_role;

commit;
