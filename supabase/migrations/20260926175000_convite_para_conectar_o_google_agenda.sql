-- CONVITE PARA CONECTAR O GOOGLE AGENDA.
--
-- 26/09/2026. Ate aqui a conexao com o Google so existia no site (Vercel):
-- exigia login no site, voltava sempre para o dominio de producao e pedia so
-- leitura da agenda. Resultado: o DEV nao tinha como conectar, o dono que so
-- fala pelo WhatsApp nao tinha como conectar, e gravar o agendamento na
-- agenda (G4) era impossivel -- faltava a permissao de escrita.
--
-- Agora a conexao nasce de um CONVITE: um codigo de uso unico, com prazo, que
-- diz de qual salao e de qual profissional e a agenda. O link com o codigo vai
-- pelo WhatsApp; quem abre autoriza no Google; a edge function
-- google-agenda-conectar troca o codigo do Google pelos tokens e grava aqui.
-- O codigo e o que prova "este link foi mandado para este salao" -- por isso
-- e aleatorio (128 bits), vale uma vez so e expira em 24 horas.

create table if not exists app.google_agenda_convites (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null unique,
  tenant_id     uuid not null references app.tenants(id) on delete cascade,
  member_name   text,
  criado_em     timestamptz not null default statement_timestamp(),
  expira_em     timestamptz not null default statement_timestamp() + interval '24 hours',
  usado_em      timestamptz,
  connection_id uuid references app.calendar_connections(id) on delete set null,
  conta_google  text
);

alter table app.google_agenda_convites enable row level security;
-- Sem politica: so as funcoes abaixo (SECURITY DEFINER) leem e escrevem.

comment on table app.google_agenda_convites is
  'Link de uso unico para conectar o Google Agenda de um salao/profissional sem passar pelo site.';

-- Cria o convite e devolve o codigo.
create or replace function app.agenda_criar_convite(p_tenant_id uuid, p_member_name text default null)
returns text
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_codigo text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  if not exists (select 1 from app.tenants t where t.id = p_tenant_id) then
    raise exception using errcode = 'P0002', message = 'SALAO_NAO_EXISTE';
  end if;
  insert into app.google_agenda_convites (codigo, tenant_id, member_name)
  values (v_codigo, p_tenant_id, nullif(trim(p_member_name), ''));
  return v_codigo;
end;
$fn$;

-- Confere o convite antes de mandar a pessoa ao Google.
create or replace function app.agenda_conferir_convite(p_codigo text)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  select coalesce(
    (select case
              when c.usado_em is not null then jsonb_build_object('ok', false, 'motivo', 'JA_USADO')
              when c.expira_em < statement_timestamp() then jsonb_build_object('ok', false, 'motivo', 'EXPIRADO')
              else jsonb_build_object('ok', true, 'tenantId', c.tenant_id, 'memberName', c.member_name)
            end
       from app.google_agenda_convites c
      where c.codigo = p_codigo),
    jsonb_build_object('ok', false, 'motivo', 'NAO_EXISTE'));
$fn$;

-- Usa o convite: grava a conexao (tokens cifrados) e queima o codigo. Tudo
-- na mesma transacao -- o `for update` impede dois usos do mesmo link.
create or replace function app.agenda_usar_convite(
  p_codigo        text,
  p_conta_google  text,
  p_access_token  text,
  p_refresh_token text,
  p_expira_em     timestamptz,
  p_scope         text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_convite record;
  v_unit_id uuid;
  v_id      uuid;
begin
  select * into v_convite from app.google_agenda_convites c where c.codigo = p_codigo for update;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'NAO_EXISTE');
  end if;
  if v_convite.usado_em is not null then
    return jsonb_build_object('ok', false, 'motivo', 'JA_USADO');
  end if;
  if v_convite.expira_em < statement_timestamp() then
    return jsonb_build_object('ok', false, 'motivo', 'EXPIRADO');
  end if;
  if p_access_token is null or length(p_access_token) = 0 then
    return jsonb_build_object('ok', false, 'motivo', 'SEM_TOKEN');
  end if;

  select u.id into v_unit_id from app.units u where u.tenant_id = v_convite.tenant_id limit 1;
  if v_unit_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'SALAO_SEM_UNIDADE');
  end if;

  insert into app.calendar_connections (
    tenant_id, unit_id, member_name, provider, external_account_email, calendar_id,
    access_token, refresh_token, token_expires_at, scope, status, last_error, tokens_encrypted
  ) values (
    v_convite.tenant_id, v_unit_id, v_convite.member_name, 'GOOGLE', p_conta_google, 'primary',
    private.encrypt_calendar_token(p_access_token),
    private.encrypt_calendar_token(p_refresh_token),
    p_expira_em, p_scope, 'ACTIVE', null, true
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
        dono_avisado_em = null,
        updated_at = statement_timestamp()
  returning id into v_id;

  update app.google_agenda_convites
     set usado_em = statement_timestamp(), connection_id = v_id, conta_google = p_conta_google
   where id = v_convite.id;

  return jsonb_build_object('ok', true, 'connectionId', v_id, 'tenantId', v_convite.tenant_id,
                            'memberName', v_convite.member_name);
end;
$fn$;

-- Fachadas para o PostgREST (a edge function chama por /rest/v1/rpc).
create or replace function public.agenda_criar_convite(p_tenant_id uuid, p_member_name text default null)
returns text language sql security definer set search_path to ''
as $$ select app.agenda_criar_convite(p_tenant_id, p_member_name); $$;

create or replace function public.agenda_conferir_convite(p_codigo text)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.agenda_conferir_convite(p_codigo); $$;

create or replace function public.agenda_usar_convite(
  p_codigo text, p_conta_google text, p_access_token text, p_refresh_token text,
  p_expira_em timestamptz, p_scope text)
returns jsonb language sql security definer set search_path to ''
as $$ select app.agenda_usar_convite(p_codigo, p_conta_google, p_access_token, p_refresh_token,
                                     p_expira_em, p_scope); $$;

revoke all on function app.agenda_criar_convite(uuid, text) from public, anon, authenticated;
revoke all on function app.agenda_conferir_convite(text) from public, anon, authenticated;
revoke all on function app.agenda_usar_convite(text, text, text, text, timestamptz, text) from public, anon, authenticated;
revoke all on function public.agenda_criar_convite(uuid, text) from public, anon, authenticated;
revoke all on function public.agenda_conferir_convite(text) from public, anon, authenticated;
revoke all on function public.agenda_usar_convite(text, text, text, text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.agenda_criar_convite(uuid, text) to service_role;
grant execute on function public.agenda_conferir_convite(text) to service_role;
grant execute on function public.agenda_usar_convite(text, text, text, text, timestamptz, text) to service_role;
