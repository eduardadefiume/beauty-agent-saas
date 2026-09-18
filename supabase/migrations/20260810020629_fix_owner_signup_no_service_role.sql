begin;

-- Correção de arquitetura: a versão anterior exigia a service_role key
-- dentro do apps/web (rota /api/auth/signup chamando a RPC via service
-- role) — isso adiciona um segredo poderoso num terceiro lugar sem
-- necessidade real. Redesenho: complete_owner_signup() passa a rodar em
-- nome do PRÓPRIO usuário já autenticado (auth.uid()), chamada não no
-- momento do cadastro (quando ainda não há sessão), e sim na primeira vez
-- que ele confirma o e-mail e volta autenticado pelo /auth/callback. Os
-- dados pessoais preenchidos no formulário viajam em user_metadata do
-- próprio auth.signUp() (Supabase já guarda isso) e são lidos dali.
-- Idempotente: repetir a chamada em logins seguintes não duplica nada.

alter table app.owner_profiles add column tenant_id uuid;
alter table app.owner_profiles add column unit_id uuid;

drop function if exists public.complete_owner_signup(
  uuid, text, date, text, text, text, text, text, text, text
);

create or replace function public.complete_owner_signup(
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
  caller_id uuid := auth.uid();
  caller_email text;
  existing app.owner_profiles%rowtype;
  new_tenant_id uuid;
  new_unit_id uuid;
  base_slug text;
  candidate_slug text;
  suffix integer := 0;
begin
  if caller_id is null then
    raise exception using errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  -- Idempotente: se este usuário já completou o cadastro antes (ex.: está
  -- só fazendo login de novo e passou de novo pelo /auth/callback), devolve
  -- o tenant já existente em vez de tentar recriar.
  select op.* into existing from app.owner_profiles op where op.auth_user_id = caller_id;
  if existing.id is not null then
    return query select existing.tenant_id, existing.unit_id;
    return;
  end if;

  select u.email into caller_email from auth.users u where u.id = caller_id;
  if caller_email is null then
    raise exception using errcode = '22023', message = 'AUTH_USER_NOT_FOUND';
  end if;

  if exists (select 1 from app.owner_profiles where cpf_digits = target_cpf_digits) then
    raise exception using errcode = '23505', message = 'CPF_ALREADY_REGISTERED';
  end if;

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

  insert into app.profiles (id, display_name, status)
  values (caller_id, target_full_name, 'ACTIVE')
  on conflict (id) do update set display_name = excluded.display_name;

  insert into app.tenants (display_name, slug, status)
  values (target_establishment_name, candidate_slug, 'ACTIVE')
  returning id into new_tenant_id;

  insert into app.units (tenant_id, name, timezone, status)
  values (new_tenant_id, 'Unidade principal', target_timezone, 'ACTIVE')
  returning id into new_unit_id;

  insert into app.configuration_drafts (tenant_id, unit_id, revision, status)
  values (new_tenant_id, new_unit_id, 1, 'DRAFT');

  insert into app.site_identities (tenant_id, site_project_id, email_normalized, role, status)
  values (new_tenant_id, 'owner-console-v1', lower(trim(caller_email)), 'OWNER', 'ACTIVE');

  insert into app.owner_profiles (
    auth_user_id, tenant_id, unit_id, full_name, birth_date, phone_digits, cpf_digits,
    address_street, address_neighborhood, address_postal_code
  ) values (
    caller_id, new_tenant_id, new_unit_id, target_full_name, target_birth_date, target_phone_digits,
    target_cpf_digits, target_address_street, target_address_neighborhood, target_address_postal_code
  );

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, correlation_id, result, metadata_minimized
  ) values (
    new_tenant_id, 'USER', caller_id, 'OWNER_SIGNUP_COMPLETED', 'tenant', new_tenant_id,
    encode(extensions.gen_random_bytes(16), 'hex'), 'SUCCESS', jsonb_build_object('unitId', new_unit_id)
  );

  return query select new_tenant_id, new_unit_id;
end;
$$;

revoke all on function public.complete_owner_signup(
  text, date, text, text, text, text, text, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.complete_owner_signup(
  text, date, text, text, text, text, text, text, text
) to authenticated;

-- resolve_login_email precisa ser chamável ANTES de existir sessão (é
-- usada durante o próprio login). Não há como restringir por auth.uid()
-- aqui — a proteção real é a RPC só devolver o e-mail (nada mais) e a
-- rota de login sempre responder com a mesma mensagem genérica de erro,
-- tanto para CPF inexistente quanto para senha errada.
grant execute on function public.resolve_login_email(text) to anon, authenticated;

commit;
