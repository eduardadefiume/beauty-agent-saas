-- O TOKEN DO SALAO TEM PRAZO DE VALIDADE.
--
-- O modelo que a Meta oferece hoje para o Cadastro Incorporado se chama, com
-- todas as letras, "Configuracao do cadastro incorporado do WhatsApp com token
-- de expiracao em 60 dias". Ou seja: todo salao que entrar pelo Embedded
-- Signup traz um token que morre em dois meses.
--
-- Sem isso registrado, o desfecho e conhecido: num dia qualquer o salao para
-- de responder as clientes, a fila de saida enche de falha de autenticacao, e
-- alguem vai descobrir olhando log -- provavelmente depois de o dono ligar
-- perguntando por que o WhatsApp "parou".
--
-- Entao a data de morte e gravada junto com o token, e existe uma consulta
-- que diz quem esta perto de calar. O aviso na tela e a renovacao vem depois;
-- o que nao podia continuar era nao saber.

alter table app.channel_connections
  add column if not exists token_expires_at timestamptz;

comment on column app.channel_connections.token_expires_at is
  'Quando o token deste salao morre. O modelo de Embedded Signup que a Meta oferece hoje entrega token de 60 dias: sem esta coluna, o salao para de responder num dia qualquer e ninguem sabe por que.';

create or replace function app.wa_connection_upsert(
  p_tenant_id      uuid,
  p_waba_id        text,
  p_phone_number_id text,
  p_token          text,
  p_purpose        text default 'CLIENTE',
  p_is_coexistence boolean default false,
  p_display_phone  text default null,
  p_verified_name  text default null,
  p_history_state  text default 'NAO_PEDIDO',
  p_actor          text default null,
  p_expires_in     integer default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
  v_expira timestamptz := case
    when p_expires_in is not null and p_expires_in > 0
      then statement_timestamp() + make_interval(secs => p_expires_in)
  end;
begin
  if coalesce(trim(p_waba_id), '') = '' or coalesce(trim(p_phone_number_id), '') = '' then
    raise exception using errcode = '22023', message = 'WABA_E_NUMERO_SAO_OBRIGATORIOS';
  end if;
  if coalesce(trim(p_token), '') = '' then
    raise exception using errcode = '22023', message = 'TOKEN_VAZIO';
  end if;
  if p_purpose not in ('CLIENTE', 'DONO') then
    raise exception using errcode = '22023', message = 'PURPOSE_INVALIDO';
  end if;

  select c.id into v_id
    from app.channel_connections c
   where c.tenant_id = p_tenant_id
     and c.channel = 'WHATSAPP'
     and c.external_sender_id = trim(p_phone_number_id);

  if v_id is null then
    insert into app.channel_connections (
      tenant_id, channel, external_account_id, external_sender_id, credential_ref,
      mode, status, purpose, allowlist_required,
      access_token_cipher, token_updated_at, token_expires_at, is_coexistence,
      display_phone_number, verified_name, history_state, history_requested_at,
      onboarded_at, onboarded_by
    ) values (
      p_tenant_id, 'WHATSAPP', trim(p_waba_id), trim(p_phone_number_id), 'db:conexao',
      'RESTRICTED', 'CONTROLLED_PRODUCTION', p_purpose,
      true,
      private.encrypt_whatsapp_token(p_token), statement_timestamp(), v_expira, p_is_coexistence,
      p_display_phone, p_verified_name, p_history_state,
      case when p_history_state = 'CONSENTIDO' then statement_timestamp() end,
      statement_timestamp(), p_actor
    )
    returning id into v_id;
  else
    update app.channel_connections
       set external_account_id  = trim(p_waba_id),
           credential_ref       = 'db:conexao',
           access_token_cipher  = private.encrypt_whatsapp_token(p_token),
           token_updated_at     = statement_timestamp(),
           token_expires_at     = v_expira,
           is_coexistence       = p_is_coexistence,
           display_phone_number = coalesce(p_display_phone, display_phone_number),
           verified_name        = coalesce(p_verified_name, verified_name),
           history_state        = p_history_state,
           history_requested_at = case
             when p_history_state = 'CONSENTIDO' then statement_timestamp()
             else history_requested_at end,
           onboarded_at         = statement_timestamp(),
           onboarded_by         = coalesce(p_actor, onboarded_by),
           updated_at           = statement_timestamp()
     where id = v_id;
  end if;

  return v_id;
end;
$function$;

drop function if exists public.wa_connection_upsert(uuid, text, text, text, text, boolean, text, text, text, text);

create function public.wa_connection_upsert(
  p_tenant_id uuid, p_waba_id text, p_phone_number_id text, p_token text,
  p_purpose text default 'CLIENTE', p_is_coexistence boolean default false,
  p_display_phone text default null, p_verified_name text default null,
  p_history_state text default 'NAO_PEDIDO', p_actor text default null,
  p_expires_in integer default null
)
returns uuid language sql security definer set search_path to ''
as $function$
  select app.wa_connection_upsert(p_tenant_id, p_waba_id, p_phone_number_id, p_token,
    p_purpose, p_is_coexistence, p_display_phone, p_verified_name, p_history_state,
    p_actor, p_expires_in);
$function$;

revoke all on function app.wa_connection_upsert(uuid, text, text, text, text, boolean, text, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.wa_connection_upsert(uuid, text, text, text, text, boolean, text, text, text, text, integer) from public, anon, authenticated;
grant execute on function public.wa_connection_upsert(uuid, text, text, text, text, boolean, text, text, text, text, integer) to service_role;

-- Quem esta perto de calar.
create or replace function app.wa_connections_expiring(p_days integer default 10)
returns table(
  connection_id uuid, tenant_id uuid, numero text, expira_em timestamptz, dias_restantes integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  select c.id, c.tenant_id,
         coalesce(c.display_phone_number, c.external_sender_id),
         c.token_expires_at,
         floor(extract(epoch from (c.token_expires_at - statement_timestamp())) / 86400)::integer
    from app.channel_connections c
   where c.token_expires_at is not null
     and c.status in ('CONTROLLED_PRODUCTION', 'PRODUCTION', 'SANDBOX_CONNECTED')
     and c.token_expires_at < statement_timestamp() + make_interval(days => greatest(1, coalesce(p_days, 10)))
   order by c.token_expires_at;
$function$;

create or replace function public.wa_connections_expiring(p_days integer default 10)
returns table(
  connection_id uuid, tenant_id uuid, numero text, expira_em timestamptz, dias_restantes integer
)
language sql stable security definer set search_path to ''
as $function$ select * from app.wa_connections_expiring(p_days); $function$;

revoke all on function app.wa_connections_expiring(integer) from public, anon, authenticated;
revoke all on function public.wa_connections_expiring(integer) from public, anon, authenticated;
grant execute on function public.wa_connections_expiring(integer) to service_role;

notify pgrst, 'reload schema';
