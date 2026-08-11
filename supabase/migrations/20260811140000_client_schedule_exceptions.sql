begin;

-- Exceção de horário por cliente: alguma cliente específica só consegue vir
-- fora do expediente normal (ex.: só sábado de manhã, só depois das 19h numa
-- terça) — em vez de abrir o expediente pra todo mundo, a Duda cadastra uma
-- janela extra válida só para aquela cliente reconhecida (por telefone ou,
-- na falta dele, pelo nome). Quem busca horário "para" essa cliente enxerga
-- expediente normal + essa janela extra; quem busca sem identificar a
-- cliente não vê a exceção.
--
-- Hoje o cadastro é manual (nome + telefone digitados aqui). Quando a
-- integração com WhatsApp existir (FV-05, depende da Duda conectar a conta),
-- o plano é a lista de contatos alimentar o mesmo campo client_phone_digits
-- em vez de reinventar o modelo — igual já vale para member_dynamic_shifts
-- com Google/Outlook.
create table app.client_schedule_exceptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  configuration_draft_id uuid not null,
  client_name text not null check (length(trim(client_name)) between 1 and 120),
  client_phone_digits text check (client_phone_digits is null or client_phone_digits ~ '^[0-9]{8,15}$'),
  weekday smallint not null check (weekday between 0 and 6),
  starts_at time not null,
  ends_at time not null,
  note text check (note is null or length(note) <= 280),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (starts_at < ends_at),
  unique (tenant_id, configuration_draft_id, id),
  foreign key (tenant_id, configuration_draft_id)
    references app.configuration_drafts(tenant_id, id) on delete cascade
);

create index client_schedule_exceptions_phone_idx
  on app.client_schedule_exceptions (tenant_id, configuration_draft_id, client_phone_digits)
  where client_phone_digits is not null;

alter table app.client_schedule_exceptions enable row level security;
create policy client_schedule_exceptions_select_member on app.client_schedule_exceptions
  for select to authenticated using (private.has_tenant_role(tenant_id));

grant select, insert, update, delete on table app.client_schedule_exceptions to authenticated, service_role;

create trigger client_schedule_exceptions_touch_updated_at
before update on app.client_schedule_exceptions
for each row execute function private.touch_updated_at();

commit;
