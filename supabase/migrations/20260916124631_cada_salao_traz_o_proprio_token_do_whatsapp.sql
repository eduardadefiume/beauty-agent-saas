-- CADA SALAO TRAZ O PROPRIO TOKEN DO WHATSAPP.
--
-- Hoje o token do WhatsApp mora numa variavel de ambiente da edge function.
-- Isso funciona com UM salao e nao funciona com dois: no Embedded Signup cada
-- negocio autoriza o app e devolve um token proprio, do WABA dele. Variavel de
-- ambiente nao tem plural.
--
-- Ontem eu ja tinha dado o primeiro passo -- `credential_ref` passou a dizer de
-- qual segredo sai o token daquela conexao. Ele resolve dois numeros meus; nao
-- resolve cinquenta saloes, porque cada um exigiria um segredo novo no projeto,
-- criado a mao.
--
-- Entao o token passa a morar na CONEXAO, cifrado, do mesmo jeito que os
-- tokens de calendario ja moram desde 17/08: chave simetrica no Vault, cifra
-- com pgp_sym, helpers em `private` sem permissao para papel de cliente
-- nenhum. Nao inventei desenho -- copiei o que ja tinha sido aprovado aqui.
--
-- `credential_ref` continua mandando, e agora com tres formas:
--   edge-secret:NOME  -> variavel de ambiente (os numeros da casa)
--   db:conexao        -> o token cifrado desta linha (cada salao que entrar)
--   nulo              -> WHATSAPP_ACCESS_TOKEN, como sempre foi
--
-- O TOKEN NUNCA VOLTA NA FILA DE SAIDA. `claim_outbox_batch` devolve o
-- `credential_ref`, nao o token: quem precisa dele pede uma vez por conexao,
-- por uma funcao que so o papel de servico alcanca. Token que viaja junto de
-- cada mensagem e token que aparece em log de lote.

-- ---------------------------------------------------------------------------
-- A chave, igual a do calendario e separada dela de proposito: vazar uma nao
-- abre a outra.
-- ---------------------------------------------------------------------------
do $$
declare
  existing_id uuid;
begin
  select id into existing_id from vault.secrets where name = 'whatsapp_token_key';
  if existing_id is null then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'base64'),
      'whatsapp_token_key',
      'Chave simetrica para cifrar tokens de WhatsApp por salao (Embedded Signup).'
    );
  end if;
end $$;

create or replace function private.whatsapp_token_key()
returns text language sql stable security definer set search_path to ''
as $$
  select s.decrypted_secret from vault.decrypted_secrets s
   where s.name = 'whatsapp_token_key' limit 1
$$;

create or replace function private.encrypt_whatsapp_token(plain text)
returns text language sql volatile security definer set search_path to ''
as $$
  select case
    when plain is null then null
    else encode(extensions.pgp_sym_encrypt(plain, private.whatsapp_token_key()), 'base64')
  end
$$;

create or replace function private.decrypt_whatsapp_token(cipher text)
returns text language sql stable security definer set search_path to ''
as $$
  select case
    when cipher is null then null
    else extensions.pgp_sym_decrypt(decode(cipher, 'base64'), private.whatsapp_token_key())
  end
$$;

revoke execute on function private.whatsapp_token_key() from public, anon, authenticated;
revoke execute on function private.encrypt_whatsapp_token(text) from public, anon, authenticated;
revoke execute on function private.decrypt_whatsapp_token(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- O que a conexao passa a guardar
-- ---------------------------------------------------------------------------
alter table app.channel_connections
  add column if not exists access_token_cipher  text,
  add column if not exists token_updated_at     timestamptz,
  add column if not exists is_coexistence       boolean not null default false,
  add column if not exists display_phone_number text,
  add column if not exists verified_name        text,
  add column if not exists history_state        text not null default 'NAO_PEDIDO',
  add column if not exists history_requested_at timestamptz,
  add column if not exists onboarded_at         timestamptz,
  add column if not exists onboarded_by         text;

alter table app.channel_connections drop constraint if exists channel_connections_history_state_check;
alter table app.channel_connections add constraint channel_connections_history_state_check
  check (history_state in ('NAO_PEDIDO', 'CONSENTIDO', 'RECEBENDO', 'CONCLUIDO', 'RECUSADO'));

comment on column app.channel_connections.is_coexistence is
  'O numero atende no aplicativo WhatsApp Business do dono E na Cloud API ao mesmo tempo. So nasce assim pelo Embedded Signup com leitura de QR.';
comment on column app.channel_connections.history_state is
  'Onde esta a sincronizacao do historico da Coexistencia. CONSENTIDO quer dizer que o dono aceitou e a Meta vai mandar; RECUSADO, que ele nao aceitou e nunca vai vir.';

-- ---------------------------------------------------------------------------
-- O token de uma conexao, para quem precisa falar com a Meta por ela
-- ---------------------------------------------------------------------------
create or replace function app.whatsapp_token(p_connection_id uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  select private.decrypt_whatsapp_token(c.access_token_cipher)
    from app.channel_connections c
   where c.id = p_connection_id;
$function$;

create or replace function public.whatsapp_token(p_connection_id uuid)
returns text language sql stable security definer set search_path to ''
as $function$ select app.whatsapp_token(p_connection_id); $function$;

revoke all on function app.whatsapp_token(uuid) from public, anon, authenticated;
revoke all on function public.whatsapp_token(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_token(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- A conexao que nasce do Embedded Signup
--
-- Idempotente pelo numero: refazer o onboarding do mesmo salao atualiza o
-- token e nao cria uma segunda linha. Onboarding refeito e caso comum -- a
-- janela de 24h da Meta expira e o dono recomeca.
-- ---------------------------------------------------------------------------
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
  p_actor          text default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
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
      access_token_cipher, token_updated_at, is_coexistence,
      display_phone_number, verified_name, history_state, history_requested_at,
      onboarded_at, onboarded_by
    ) values (
      p_tenant_id, 'WHATSAPP', trim(p_waba_id), trim(p_phone_number_id), 'db:conexao',
      'RESTRICTED', 'CONTROLLED_PRODUCTION', p_purpose,
      -- Salao que acabou de conectar comeca em modo de teste: so quem estiver
      -- na lista recebe resposta. Ligar para todo mundo e decisao do dono, na
      -- tela, depois de ele ver o agente responder.
      true,
      private.encrypt_whatsapp_token(p_token), statement_timestamp(), p_is_coexistence,
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

create or replace function public.wa_connection_upsert(
  p_tenant_id uuid, p_waba_id text, p_phone_number_id text, p_token text,
  p_purpose text default 'CLIENTE', p_is_coexistence boolean default false,
  p_display_phone text default null, p_verified_name text default null,
  p_history_state text default 'NAO_PEDIDO', p_actor text default null
)
returns uuid language sql security definer set search_path to ''
as $function$
  select app.wa_connection_upsert(p_tenant_id, p_waba_id, p_phone_number_id, p_token,
    p_purpose, p_is_coexistence, p_display_phone, p_verified_name, p_history_state, p_actor);
$function$;

revoke all on function app.wa_connection_upsert(uuid, text, text, text, text, boolean, text, text, text, text) from public, anon, authenticated;
revoke all on function public.wa_connection_upsert(uuid, text, text, text, text, boolean, text, text, text, text) from public, anon, authenticated;
grant execute on function public.wa_connection_upsert(uuid, text, text, text, text, boolean, text, text, text, text) to service_role;

notify pgrst, 'reload schema';
