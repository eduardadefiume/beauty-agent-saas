begin;

-- Trio de RPCs para a sincronização real dos eventos do Google Agenda:
-- 1) lista conexões ativas COM token, só para a rota de sincronização
--    server-to-server (nunca passa pelo proxy genérico /api/configuration,
--    igual o saveCalendarConnection já não passa);
-- 2) grava os eventos buscados na API do Google, substituindo a janela
--    sincronizada (assim cancelamento no Google também reflete aqui);
-- 3) lista os eventos já sincronizados, sem token nenhum, para a tela
--    mostrar um calendário de verdade em vez de só "conectado/desconectado".
create function public.site_list_calendar_connections_for_sync(
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
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'unitId', c.unit_id,
      'provider', c.provider,
      'memberName', c.member_name,
      'calendarId', c.calendar_id,
      'accessToken', c.access_token,
      'refreshToken', c.refresh_token,
      'tokenExpiresAt', c.token_expires_at
    ))
    from app.calendar_connections c
    where c.tenant_id = target_tenant_id and c.status in ('ACTIVE', 'ERROR')
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.site_list_calendar_connections_for_sync(text, text, uuid) to service_role;

-- Substitui, para uma conexão, tudo que estava sincronizado dentro da
-- janela de busca por essa nova leva de eventos — assim um evento
-- cancelado no Google some daqui também, sem precisar de uma segunda
-- chamada só para detectar remoção. target_events é um array de
-- {externalEventId, startsAt, endsAt, title}.
create function public.site_record_calendar_shift_sync(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_connection_id uuid,
  target_window_start timestamptz,
  target_window_end timestamptz,
  target_events jsonb,
  target_new_access_token text,
  target_new_token_expires_at timestamptz,
  target_error text
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  connection_row app.calendar_connections%rowtype;
  event record;
  inserted_count integer := 0;
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  select * into connection_row
    from app.calendar_connections
   where id = target_connection_id and tenant_id = target_tenant_id
   for update;

  if connection_row.id is null then
    raise exception using errcode = 'P0002', message = 'CONNECTION_NOT_FOUND';
  end if;

  if target_error is not null then
    update app.calendar_connections
       set status = 'ERROR', last_error = target_error, updated_at = statement_timestamp()
     where id = target_connection_id;
    return jsonb_build_object('ok', false, 'error', target_error);
  end if;

  delete from app.member_calendar_shifts
   where connection_id = target_connection_id
     and time_range && tstzrange(target_window_start, target_window_end, '[)');

  for event in select * from jsonb_to_recordset(target_events)
    as x(external_event_id text, starts_at timestamptz, ends_at timestamptz, title text)
  loop
    if event.starts_at is null or event.ends_at is null or event.ends_at <= event.starts_at then
      continue;
    end if;
    insert into app.member_calendar_shifts (
      tenant_id, unit_id, connection_id, member_name, external_event_id, time_range, title
    ) values (
      target_tenant_id, connection_row.unit_id, target_connection_id, connection_row.member_name,
      event.external_event_id, tstzrange(event.starts_at, event.ends_at, '[)'), event.title
    )
    on conflict (connection_id, external_event_id) do update
      set time_range = excluded.time_range, title = excluded.title, synced_at = statement_timestamp();
    inserted_count := inserted_count + 1;
  end loop;

  update app.calendar_connections
     set status = 'ACTIVE',
         last_synced_at = statement_timestamp(),
         last_error = null,
         access_token = coalesce(target_new_access_token, access_token),
         token_expires_at = coalesce(target_new_token_expires_at, token_expires_at),
         updated_at = statement_timestamp()
   where id = target_connection_id;

  return jsonb_build_object('ok', true, 'eventsSynced', inserted_count);
end;
$function$;

grant execute on function public.site_record_calendar_shift_sync(
  text, text, uuid, uuid, timestamptz, timestamptz, jsonb, text, timestamptz, text
) to service_role;

-- Para a tela mostrar um calendário de verdade com o que veio do Google,
-- sem token nenhum.
create function public.site_list_calendar_shifts(
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
      'id', s.id,
      'connectionId', s.connection_id,
      'memberName', s.member_name,
      'title', s.title,
      'startsAt', lower(s.time_range),
      'endsAt', upper(s.time_range)
    ) order by lower(s.time_range))
    from app.member_calendar_shifts s
    where s.tenant_id = target_tenant_id
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.site_list_calendar_shifts(text, text, uuid) to service_role;

commit;
