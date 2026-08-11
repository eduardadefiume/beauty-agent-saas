begin;

-- Reserva de teste de mechas: registro leve, SEPARADO de app.appointments —
-- de propósito. O teste é "melhor esforço" (Duda: "não precisa ter horário
-- livre na agenda pra isso, teste não atrapalha atendimentos"): o motor
-- procura um horário livre pra evitar marcar duas colorações de teste em
-- cima uma da outra, mas NÃO reserva em app.member_occupancies/
-- resource_occupancies — então um atendimento de verdade ainda pode cair
-- em cima do horário do teste depois. É por isso que não é um
-- app.appointments normal (que também exigiria um app.services de verdade
-- só pra representar o teste, o que a Duda não quer cadastrar).
create table app.strand_test_bookings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  unit_id uuid not null,
  main_appointment_id uuid not null,
  member_id uuid not null,
  member_name text not null check (length(trim(member_name)) between 1 and 160),
  resource_id uuid,
  time_range tstzrange not null,
  status text not null default 'CONFIRMED' check (status in ('CONFIRMED', 'CANCELLED')),
  correlation_id text not null check (length(correlation_id) between 8 and 128),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  check (lower_inc(time_range) and not upper_inc(time_range) and not isempty(time_range)),
  unique (tenant_id, main_appointment_id),
  foreign key (tenant_id, unit_id) references app.units(tenant_id, id) on delete restrict,
  foreign key (main_appointment_id) references app.appointments(id) on delete cascade,
  -- Mesmo padrão de concorrência de member_occupancies_no_overlap: impede
  -- duas reservas de teste (não atendimentos reais) baterem de frente pra
  -- mesma colorista, mesmo sob corrida.
  exclude using gist (tenant_id with =, member_id with =, time_range with &&) where (status = 'CONFIRMED')
);

create index strand_test_bookings_unit_time_idx
  on app.strand_test_bookings (tenant_id, unit_id, time_range);

alter table app.strand_test_bookings enable row level security;
create policy strand_test_bookings_select_member on app.strand_test_bookings
  for select to authenticated using (private.has_tenant_role(tenant_id));

grant select on table app.strand_test_bookings to authenticated;
grant select, insert, update on table app.strand_test_bookings to service_role;

create trigger strand_test_bookings_touch_updated_at
before update on app.strand_test_bookings
for each row execute function private.touch_updated_at();

commit;
