begin;

-- Conexão real com Google Agenda (e depois Outlook) por unidade, e
-- opcionalmente por profissional específico (member_name, não member_id,
-- porque team_members é recriado a cada save do rascunho e o id muda
-- toda hora — nome é a chave estável nesse sistema, é assim que
-- site_replace_configuration já resolve competências e recursos).
-- Token fica só aqui, nunca sai pro app do navegador: só o service_role lê.
create table app.calendar_connections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  member_name text,
  provider text not null check (provider in ('GOOGLE', 'MICROSOFT')),
  external_account_email text,
  calendar_id text not null default 'primary',
  access_token text,
  refresh_token text,
  token_expires_at timestamptz,
  scope text,
  status text not null default 'PENDING' check (status in ('PENDING', 'ACTIVE', 'ERROR', 'DISCONNECTED')),
  last_synced_at timestamptz,
  last_error text,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete cascade,
  unique (tenant_id, unit_id, provider, member_name)
);

alter table app.calendar_connections enable row level security;
-- Ninguém autenticado enxerga essa tabela direto (tem token dentro) — só o
-- service_role, chamado pelas RPCs abaixo, que devolvem status sem o token.
grant select, insert, update, delete on table app.calendar_connections to service_role;

create trigger calendar_connections_touch_updated_at
before update on app.calendar_connections
for each row execute function private.touch_updated_at();

-- Compromissos vindos do calendário externo (Google/Outlook). Aqui é o
-- OPOSTO do calendário Dinâmica do configurador: lá a Duda marca quando a
-- pessoa VAI trabalhar (abre disponibilidade); aqui é quando a pessoa JÁ
-- TEM algo marcado no Google/Outlook (fecha disponibilidade, vira ocupado)
-- — um dentista, um compromisso pessoal, o que for. As duas coisas
-- convivem: o expediente normal da pessoa continua valendo, e um evento no
-- calendário externo só bloqueia aquele horário específico em cima dele.
--
-- Tabela separada de member_dynamic_shifts de propósito: essa aqui é
-- sempre atual (a sincronização escreve direto), enquanto
-- member_dynamic_shifts pertence ao rascunho e é apagada e recriada toda
-- vez que a Duda salva alguma coisa no configurador — se a sincronização
-- escrevesse lá, um save qualquer podia apagar os compromissos do Google
-- sem querer.
create table app.member_calendar_shifts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  connection_id uuid not null references app.calendar_connections(id) on delete cascade,
  member_name text,
  external_event_id text not null,
  time_range tstzrange not null,
  title text,
  synced_at timestamptz not null default statement_timestamp(),
  check (lower_inc(time_range) and not upper_inc(time_range) and not isempty(time_range)),
  unique (connection_id, external_event_id)
);

create index member_calendar_shifts_lookup_idx
  on app.member_calendar_shifts (tenant_id, unit_id, member_name, time_range);

alter table app.member_calendar_shifts enable row level security;
grant select, insert, update, delete on table app.member_calendar_shifts to service_role;

commit;
