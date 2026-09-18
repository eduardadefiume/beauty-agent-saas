begin;

create policy site_identities_service_role_all
  on app.site_identities
  for all
  to service_role
  using (true)
  with check (true);

comment on policy site_identities_service_role_all on app.site_identities is
  'Explicit server-only policy. Browser roles have neither grants nor policies.';

commit;
