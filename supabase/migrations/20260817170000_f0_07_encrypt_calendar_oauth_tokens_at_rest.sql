-- F0-07: cifrar tokens OAuth de calendario em repouso.
--
-- Ate aqui app.calendar_connections.access_token e refresh_token eram colunas
-- text em claro. Combinado com a exposicao fechada em F0-01b, qualquer leitura
-- indevida entregava um refresh token utilizavel do Google.
--
-- Estrategia: chave simetrica no Vault do Supabase, cifragem com pgcrypto.
-- Os NOMES das colunas sao mantidos de proposito: assim
-- site_disconnect_calendar_connection, que apenas anula os campos, continua
-- correta sem alteracao. O conteudo passa a ser texto cifrado em base64.
--
-- Auditoria previa: apenas quatro funcoes referenciam essas colunas
-- (save, record_sync, list_for_sync e disconnect). As tres primeiras sao
-- reescritas aqui; a quarta nao precisa mudar.
--
-- Verificado apos aplicar, com a conexao real do piloto:
--   coluna    -> "ww0EBwMC..." (pacote PGP em base64), 230 caracteres
--   funcao    -> "1//..." (formato de refresh token do Google)
--   anon      -> total de funcoes de public alcancaveis permaneceu em zero

-- 1. Chave no Vault, criada uma unica vez.
do $$
declare
  existing_id uuid;
begin
  select id into existing_id from vault.secrets where name = 'calendar_token_key';
  if existing_id is null then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'base64'),
      'calendar_token_key',
      'Chave simetrica para cifrar tokens OAuth de calendario (F0-07).'
    );
  end if;
end $$;

-- 2. Helpers. Ficam em private e nao sao concedidos a nenhum papel de cliente.
create or replace function private.calendar_token_key()
returns text language sql stable security definer set search_path to ''
as $$
  select s.decrypted_secret from vault.decrypted_secrets s
   where s.name = 'calendar_token_key' limit 1
$$;

-- volatile, nao stable: pgp_sym_encrypt usa IV aleatorio a cada chamada.
create or replace function private.encrypt_calendar_token(plain text)
returns text language sql volatile security definer set search_path to ''
as $$
  select case
    when plain is null then null
    else encode(extensions.pgp_sym_encrypt(plain, private.calendar_token_key()), 'base64')
  end
$$;

create or replace function private.decrypt_calendar_token(cipher text)
returns text language sql stable security definer set search_path to ''
as $$
  select case
    when cipher is null then null
    else extensions.pgp_sym_decrypt(decode(cipher, 'base64'), private.calendar_token_key())
  end
$$;

revoke execute on function private.calendar_token_key() from public, anon, authenticated;
revoke execute on function private.encrypt_calendar_token(text) from public, anon, authenticated;
revoke execute on function private.decrypt_calendar_token(text) from public, anon, authenticated;

-- 3. Marcador que torna a migracao de dados idempotente.
alter table app.calendar_connections
  add column if not exists tokens_encrypted boolean not null default false;

update app.calendar_connections
   set access_token  = private.encrypt_calendar_token(access_token),
       refresh_token = private.encrypt_calendar_token(refresh_token),
       tokens_encrypted = true
 where tokens_encrypted = false;

-- A partir daqui toda linha nova ja nasce cifrada.
alter table app.calendar_connections alter column tokens_encrypted set default true;

-- 4. Escrita cifrada na criacao/atualizacao da conexao.
create or replace function public.site_save_calendar_connection(
  target_site_project_id text, target_email text, target_tenant_id uuid,
  target_provider text, target_member_name text, target_external_account_email text,
  target_calendar_id text, target_access_token text, target_refresh_token text,
  target_token_expires_at timestamp with time zone, target_scope text
)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  target_unit_id uuid;
  new_id uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
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
    access_token, refresh_token, token_expires_at, scope, status, last_error, tokens_encrypted
  ) values (
    target_tenant_id, target_unit_id, target_member_name, target_provider, target_external_account_email,
    coalesce(nullif(target_calendar_id, ''), 'primary'),
    private.encrypt_calendar_token(target_access_token),
    private.encrypt_calendar_token(target_refresh_token),
    target_token_expires_at, target_scope, 'ACTIVE', null, true
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
        tokens_encrypted = true,
        updated_at = statement_timestamp()
  returning id into new_id;

  return jsonb_build_object('connectionId', new_id, 'status', 'ACTIVE');
end;
$function$;

-- 5. Renovacao do access token durante o sync tambem grava cifrado.
create or replace function public.site_record_calendar_shift_sync(
  target_site_project_id text, target_email text, target_tenant_id uuid,
  target_connection_id uuid, target_window_start timestamp with time zone,
  target_window_end timestamp with time zone, target_events jsonb,
  target_new_access_token text, target_new_token_expires_at timestamp with time zone,
  target_error text
)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  connection_row app.calendar_connections%rowtype;
  event record;
  inserted_count integer := 0;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
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
         access_token = coalesce(private.encrypt_calendar_token(target_new_access_token), access_token),
         token_expires_at = coalesce(target_new_token_expires_at, token_expires_at),
         updated_at = statement_timestamp()
   where id = target_connection_id;

  return jsonb_build_object('ok', true, 'eventsSynced', inserted_count);
end;
$function$;

-- 6. Leitura decifra apenas para quem ja passou pela checagem de tenant/papel.
create or replace function public.site_list_calendar_connections_for_sync(
  target_site_project_id text, target_email text, target_tenant_id uuid
)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'unitId', c.unit_id,
      'provider', c.provider,
      'memberName', c.member_name,
      'calendarId', c.calendar_id,
      'accessToken', private.decrypt_calendar_token(c.access_token),
      'refreshToken', private.decrypt_calendar_token(c.refresh_token),
      'tokenExpiresAt', c.token_expires_at
    ))
    from app.calendar_connections c
    where c.tenant_id = target_tenant_id and c.status in ('ACTIVE', 'ERROR')
  ), '[]'::jsonb);
end;
$function$;

-- 7. CREATE OR REPLACE pode restaurar o grant padrao a PUBLIC.
-- Reaplicar o fecho de F0-01b nas tres funcoes recriadas.
revoke execute on function public.site_save_calendar_connection(text,text,uuid,text,text,text,text,text,text,timestamptz,text) from public, anon, authenticated;
revoke execute on function public.site_record_calendar_shift_sync(text,text,uuid,uuid,timestamptz,timestamptz,jsonb,text,timestamptz,text) from public, anon, authenticated;
revoke execute on function public.site_list_calendar_connections_for_sync(text,text,uuid) from public, anon, authenticated;
