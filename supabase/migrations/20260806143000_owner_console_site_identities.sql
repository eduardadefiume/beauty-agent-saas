-- Links the owner's authenticated email to her tenants under the new
-- self-hosted "owner console" app (Next.js + Supabase Auth magic link),
-- replacing the ChatGPT Sites-hosted configurator. Uses the existing
-- app.site_identities table and RPC contract (site_list_tenants,
-- site_load_configuration, site_replace_configuration,
-- site_publish_configuration) unchanged; only the site_project_id
-- namespace and the caller-trust mechanism (verified Supabase JWT instead
-- of a shared static secret) are new. See supabase/functions/owner-console-api.

insert into app.site_identities (tenant_id, site_project_id, email_normalized)
select t.id, 'owner-console-v1', lower('eddigital.oficial@gmail.com')
from app.tenants t
where t.slug in ('salao-do-william', 'studio-da-jack', 'piloto-eduarda')
on conflict (tenant_id, site_project_id, email_normalized) do nothing;
