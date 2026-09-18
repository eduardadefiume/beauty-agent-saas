begin;

-- Cadastro de proprietários (donas/donos de salão/studio que vão comprar e
-- usar o sistema) com e-mail+senha, dados pessoais e criação automática do
-- tenant/unidade — hoje a única forma de acesso é a Duda inserir uma linha
-- manual em app.site_identities por SQL para cada novo cliente do software.
-- Isso substitui esse passo manual por um cadastro de verdade.
--
-- Público: donas de salão/studio que vão USAR o configurador (clientes do
-- SEU software). Os clientes finais (quem corta o cabelo) continuam sendo
-- atendidos só pelo WhatsApp — nada aqui é para eles.

create extension if not exists unaccent with schema extensions;

create table app.owner_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) between 1 and 160),
  birth_date date not null check (birth_date between '1900-01-01' and current_date),
  phone_digits text not null check (phone_digits ~ '^[0-9]{10,11}$'),
  cpf_digits text not null check (cpf_digits ~ '^[0-9]{11}$'),
  address_street text not null check (length(trim(address_street)) between 1 and 200),
  address_neighborhood text not null check (length(trim(address_neighborhood)) between 1 and 120),
  address_postal_code text not null check (address_postal_code ~ '^[0-9]{8}$'),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (auth_user_id),
  unique (cpf_digits)
);

alter table app.owner_profiles enable row level security;
alter table app.owner_profiles force row level security;

create policy owner_profiles_self_select on app.owner_profiles
  for select to authenticated
  using (auth_user_id = auth.uid());

grant select on app.owner_profiles to authenticated;
grant select, insert, update, delete on app.owner_profiles to service_role;

create trigger owner_profiles_touch_updated_at
before update on app.owner_profiles
for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- public.complete_owner_signup — chamada pela rota /api/auth/signup logo
-- depois de auth.signUp() criar o usuário (ainda não confirmado). Cria o
-- perfil pessoal, o tenant, a unidade padrão, o primeiro rascunho de
-- configuração e o vínculo em app.site_identities — tudo numa transação.
-- Só service_role executa (chamada server-side com a service role key,
-- nunca a partir do navegador).
-- ---------------------------------------------------------------------------

create or replace function public.complete_owner_signup(
  target_auth_user_id uuid,
  target_full_name text,
  target_birth_date date,
  target_phone_digits text,
  target_cpf_digits text,
  target_address_street text,
  target_address_neighborhood text,
  target_address_postal_code text,
  target_establishment_name text,
  target_timezone text default 'America/Sao_Paulo'
)
returns table (tenant_id uuid, unit_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_tenant_id uuid;
  new_unit_id uuid;
  base_slug text;
  candidate_slug text;
  suffix integer := 0;
  owner_email text;
begin
  if target_auth_user_id is null then
    raise exception using errcode = '22023', message = 'INVALID_AUTH_USER';
  end if;

  select u.email into owner_email from auth.users u where u.id = target_auth_user_id;
  if owner_email is null then
    raise exception using errcode = '22023', message = 'AUTH_USER_NOT_FOUND';
  end if;

  if exists (select 1 from app.owner_profiles where auth_user_id = target_auth_user_id) then
    raise exception using errcode = '23505', message = 'PROFILE_ALREADY_EXISTS';
  end if;
  if exists (select 1 from app.owner_profiles where cpf_digits = target_cpf_digits) then
    raise exception using errcode = '23505', message = 'CPF_ALREADY_REGISTERED';
  end if;

  insert into app.profiles (id, display_name, status)
  values (target_auth_user_id, target_full_name, 'ACTIVE')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into app.owner_profiles (
    auth_user_id, full_name, birth_date, phone_digits, cpf_digits,
    address_street, address_neighborhood, address_postal_code
  ) values (
    target_auth_user_id, target_full_name, target_birth_date, target_phone_digits, target_cpf_digits,
    target_address_street, target_address_neighborhood, target_address_postal_code
  );

  base_slug := regexp_replace(
    lower(extensions.unaccent(trim(target_establishment_name))), '[^a-z0-9]+', '-', 'g'
  );
  base_slug := trim(both '-' from base_slug);
  if base_slug = '' then
    base_slug := 'estabelecimento';
  end if;
  candidate_slug := base_slug;
  while exists (select 1 from app.tenants where slug = candidate_slug) loop
    suffix := suffix + 1;
    candidate_slug := base_slug || '-' || suffix::text;
  end loop;

  insert into app.tenants (display_name, slug, status)
  values (target_establishment_name, candidate_slug, 'ACTIVE')
  returning id into new_tenant_id;

  insert into app.units (tenant_id, name, timezone, status)
  values (new_tenant_id, 'Unidade principal', target_timezone, 'ACTIVE')
  returning id into new_unit_id;

  insert into app.configuration_drafts (tenant_id, unit_id, revision, status)
  values (new_tenant_id, new_unit_id, 1, 'DRAFT');

  insert into app.site_identities (tenant_id, site_project_id, email_normalized, role, status)
  values (new_tenant_id, 'owner-console-v1', lower(trim(owner_email)), 'OWNER', 'ACTIVE');

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, correlation_id, result, metadata_minimized
  ) values (
    new_tenant_id, 'USER', target_auth_user_id, 'OWNER_SIGNUP_COMPLETED', 'tenant', new_tenant_id,
    encode(extensions.gen_random_bytes(16), 'hex'), 'SUCCESS', jsonb_build_object('unitId', new_unit_id)
  );

  return query select new_tenant_id, new_unit_id;
end;
$$;

revoke all on function public.complete_owner_signup(
  uuid, text, date, text, text, text, text, text, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.complete_owner_signup(
  uuid, text, date, text, text, text, text, text, text, text
) to service_role;

-- ---------------------------------------------------------------------------
-- public.resolve_login_email — permite "entrar com CPF": a rota de login
-- resolve CPF -> e-mail aqui (server-side, service_role) antes de chamar
-- signInWithPassword. Resposta idêntica (nenhuma) tanto para CPF inexistente
-- quanto para erro — quem decide a mensagem final ao usuário é a rota, que
-- usa sempre a mesma frase genérica para não revelar qual CPF existe.
-- ---------------------------------------------------------------------------

create or replace function public.resolve_login_email(target_cpf_digits text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.email
    from app.owner_profiles op
    join auth.users u on u.id = op.auth_user_id
   where op.cpf_digits = target_cpf_digits
   limit 1
$$;

revoke all on function public.resolve_login_email(text) from public, anon, authenticated, service_role;
grant execute on function public.resolve_login_email(text) to service_role;

commit;
