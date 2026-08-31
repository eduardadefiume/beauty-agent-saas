-- O agente ofereceu "sabado 05/09 as 8h" consultando a agenda para "Mechas
-- morena iluminada" (240 min). Na leva seguinte, com a cliente ja tendo
-- aceitado, ele consultou de novo -- mas para "Mechas loiras - teste na
-- semana" (360 min). Sabado tem duas janelas: 08:00-12:00 e 13:00-18:00.
-- 240 min cabem nas duas. 360 min nao cabem em nenhuma. A agenda respondeu
-- zero horarios, e o agente foi perguntar para a dona se podia confirmar
-- mesmo assim um horario que a agenda dizia nao existir.
--
-- A agenda estava certa nas duas vezes. O que mudou foi o servico, e mudou
-- sozinho: a cliente nao pediu nada diferente.
--
-- Esta tabela guarda em que servico a conversa esta, com os horarios que a
-- ultima consulta devolveu. A proxima leva le isso de volta e consulta o
-- MESMO servico -- e, se a cliente aceitou, reserva o horario que ja estava
-- na mesa sem precisar procurar de novo.
create table if not exists app.agent_scheduling_focus (
  conversation_id            uuid primary key
                             references app.crm_conversations (id) on delete cascade,
  tenant_id                  uuid not null references app.tenants (id) on delete cascade,
  service_id                 uuid not null references app.services (id) on delete cascade,
  configuration_version_id   uuid,
  candidates                 jsonb not null default '[]'::jsonb,
  searched_at                timestamptz not null default now()
);

create index if not exists agent_scheduling_focus_tenant_idx
  on app.agent_scheduling_focus (tenant_id, searched_at desc);

-- Grava o foco a cada consulta de agenda. Uma linha por conversa: a consulta
-- mais recente manda. Devolve o foco ja gravado -- com o nome do servico --
-- para o agente poder dizer a cliente de que servico ele esta falando sem uma
-- segunda ida ao banco.
create or replace function app.agent_set_scheduling_focus(
  p_tenant_id                uuid,
  p_conversation_id          uuid,
  p_service_id               uuid,
  p_configuration_version_id uuid,
  p_candidates               jsonb
) returns jsonb
language sql
security definer
set search_path = app, public
as $$
  insert into app.agent_scheduling_focus as f
    (conversation_id, tenant_id, service_id, configuration_version_id, candidates, searched_at)
  values
    (p_conversation_id, p_tenant_id, p_service_id, p_configuration_version_id,
     coalesce(p_candidates, '[]'::jsonb), now())
  on conflict (conversation_id) do update
    set tenant_id                = excluded.tenant_id,
        service_id               = excluded.service_id,
        configuration_version_id = excluded.configuration_version_id,
        candidates               = excluded.candidates,
        searched_at              = excluded.searched_at;

  select app.agent_scheduling_focus(p_conversation_id);
$$;

-- Le o foco com o nome do servico junto. O nome existe para o agente poder
-- dizer a cliente de que servico ele esta falando sem ter que adivinhar.
create or replace function app.agent_scheduling_focus(p_conversation_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = app, public
as $$
  select jsonb_build_object(
    'serviceId',                f.service_id,
    'serviceName',              s.name,
    'configurationVersionId',   f.configuration_version_id,
    'candidates',               f.candidates,
    'searchedAt',               f.searched_at,
    'ageMinutes',               floor(extract(epoch from (now() - f.searched_at)) / 60)::int
  )
  from app.agent_scheduling_focus f
  join app.services s on s.id = f.service_id
  where f.conversation_id = p_conversation_id;
$$;

-- Depois de marcar, o foco morre: a proxima conversa sobre agenda comeca do
-- zero em vez de arrastar candidatos de um agendamento que ja aconteceu.
create or replace function app.agent_clear_scheduling_focus(p_conversation_id uuid)
returns void
language sql
security definer
set search_path = app, public
as $$
  delete from app.agent_scheduling_focus where conversation_id = p_conversation_id;
$$;

create or replace function public.agent_set_scheduling_focus(
  p_tenant_id uuid, p_conversation_id uuid, p_service_id uuid,
  p_configuration_version_id uuid, p_candidates jsonb
) returns jsonb language sql security definer set search_path = app, public as $$
  select app.agent_set_scheduling_focus(p_tenant_id, p_conversation_id, p_service_id,
                                        p_configuration_version_id, p_candidates);
$$;

create or replace function public.agent_scheduling_focus(p_conversation_id uuid)
returns jsonb language sql stable security definer set search_path = app, public as $$
  select app.agent_scheduling_focus(p_conversation_id);
$$;

create or replace function public.agent_clear_scheduling_focus(p_conversation_id uuid)
returns void language sql security definer set search_path = app, public as $$
  select app.agent_clear_scheduling_focus(p_conversation_id);
$$;

revoke all on function public.agent_set_scheduling_focus(uuid, uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.agent_scheduling_focus(uuid) from public, anon, authenticated;
revoke all on function public.agent_clear_scheduling_focus(uuid) from public, anon, authenticated;
grant execute on function public.agent_set_scheduling_focus(uuid, uuid, uuid, uuid, jsonb) to service_role;
grant execute on function public.agent_scheduling_focus(uuid) to service_role;
grant execute on function public.agent_clear_scheduling_focus(uuid) to service_role;

alter table app.agent_scheduling_focus enable row level security;
