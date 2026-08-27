-- A ficha da cliente.
--
-- POR QUE ELA VEM ANTES DO CLASSIFICADOR DE FOTO. O William tem 471 clientes
-- no histórico e 98 delas com quatro visitas ou mais. A maior parte das
-- conversas dele é com gente que ele já atende -- e para essas, foto nenhuma
-- é necessária: o agente precisa lembrar, não adivinhar. O reconhecimento de
-- imagem atende a minoria (cliente nova), e por isso vem depois.
--
-- POR QUE NÃO ENTRA NA CONFIGURAÇÃO. As tabelas de configuração são clonadas
-- a cada publicação, com ids novos. Ficha de cliente amarrada ali viraria
-- órfã toda vez que a dona publicasse -- levando junto o histórico e as fotos.
-- A ficha pertence ao TENANT e é operacional, como a conversa: ela não é algo
-- que se publica, é algo que acontece.
--
-- A IDENTIDADE JÁ EXISTE. `app.crm_contacts` é quem a cliente é, e já está
-- ligada ao WhatsApp e às conversas. A ficha não cria uma segunda identidade:
-- ela é um perfil pendurado no contato que o sistema já reconhece. Um contato
-- tem no máximo uma ficha, e ela pode não existir.
--
-- O DESENHO SAIU DO DADO REAL. Os campos abaixo vieram da extração de 551
-- conversas e 2.281 agendamentos do salão do William, não de suposição. Onde
-- o dado real mostrou que uma coluna quase nunca é preenchida -- o tom, citado
-- em 13 de 286 fichas --, ela é opcional e o agente não pode contar com ela.

-- ---------------------------------------------------------------- perfil

create table if not exists app.client_profiles (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references app.tenants(id) on delete cascade,
  contact_id uuid not null references app.crm_contacts(id) on delete cascade,

  -- Como o William chama ela. No histórico dele o vocativo mais comum é
  -- "amore"; o primeiro nome aparece bem menos. Guardar o nome preferido é o
  -- que permite o agente escolher entre os dois sem soar artificial.
  preferred_name text,

  -- PRE_CADASTRO é ficha que o agente abriu sozinho a partir da conversa e
  -- ninguém conferiu. O agente PODE ler uma ficha nesse estado, mas trata o
  -- conteúdo como declarado pela cliente, não como verificado pelo salão.
  status text not null default 'PRE_CADASTRO'
    check (status in ('PRE_CADASTRO', 'COMPLETO', 'ARQUIVADA')),

  -- Classificação do cabelo. Aponta para a régua do salão (módulo
  -- Conhecimento), que pode ainda não existir -- por isso nulo é permitido e
  -- não é erro. Uma ficha sem classificação continua útil: o histórico de
  -- valor e duração já responde a maioria das perguntas.
  length_option_id    uuid references app.knowledge_options(id) on delete set null,
  thickness_option_id uuid references app.knowledge_options(id) on delete set null,

  -- O que a cliente contou na conversa. São as perguntas que o roteiro de
  -- investigação faz; ficam aqui como colunas porque são um conjunto pequeno
  -- e fixo, e porque o agente precisa lê-las inteiras a cada mensagem.
  has_chemistry     boolean,
  chemistry_kind    text,
  chemistry_last_at date,
  chemistry_formol  text check (chemistry_formol in ('COM_FORMOL', 'SEM_FORMOL', 'NAO_SABE')),
  has_color         boolean,
  color_last_at     date,
  tone_wanted       text,

  -- Consentimento de guardar foto e ficha técnica.
  --
  -- NÃO fica em app.crm_contact_consents de propósito. Aquela tabela modela
  -- consentimento de CANAL -- transacional e marketing --, capturado por um
  -- ato da própria cliente no WhatsApp. Este aqui é outro bicho: é presencial,
  -- dado de viva voz no salão, e registrado pelo dono. Natureza diferente,
  -- prova diferente. Misturar os dois faria a evidência de um contaminar o
  -- outro.
  --
  -- A exigência da LGPD não é o papel, é conseguir mostrar o registro depois.
  -- Por isso guarda quem registrou e quando, não só um "sim".
  photo_consent_granted_at  timestamptz,
  photo_consent_recorded_by text,
  photo_consent_note        text,

  -- Observação livre do dono sobre o cabelo dela. É onde cabe o que nenhuma
  -- coluna prevê -- e o histórico do William mostra que isso existe: ele salva
  -- contato como "Muito Cabelo Progressiva 450".
  notes text,

  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),

  unique (tenant_id, contact_id)
);

comment on table app.client_profiles is
  'A ficha da cliente: um perfil pendurado no contato que já existe. Pertence ao tenant e não à configuração -- não é publicada, é acumulada.';
comment on column app.client_profiles.status is
  'PRE_CADASTRO = o agente abriu sozinho e ninguém conferiu. COMPLETO = o dono fechou depois do atendimento.';

-- ------------------------------------------------- o que ela faz, e de quanto em quanto

-- Família do procedimento. Saiu das 22 categorias que aparecem no histórico
-- real do salão, agrupadas pelo que muda a conversa: cor exige teste de
-- mechas, alisamento não; tratamento tem cadência curta, corte tem longa.
do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'procedure_family') then
    create type app.procedure_family as enum ('COR', 'ALISAMENTO', 'TRATAMENTO', 'CORTE', 'OUTRO');
  end if;
end $$;

create table if not exists app.client_procedures (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references app.tenants(id) on delete cascade,
  profile_id uuid not null references app.client_profiles(id) on delete cascade,

  family app.procedure_family not null,
  -- O nome como o salão fala: "Luzes/Mechas", "Progressiva Violet". Texto e
  -- não referência ao catálogo, porque o histórico é anterior ao catálogo e
  -- porque o salão renomeia serviço sem querer reescrever o passado.
  label  text not null,

  times_done   integer not null default 1 check (times_done >= 0),
  last_done_at date,

  -- De quanto em quanto tempo ela volta para ISTO. No histórico real as
  -- cadências vão de 7 dias (cronograma capilar) a 161 dias (luzes). É o que
  -- permite o agente saber que a cliente está atrasada sem ninguém calcular.
  --
  -- Nulo quando não há visita suficiente para dizer. Uma visita não é uma
  -- cadência, e fingir que é produziria cobrança de retorno em cima de quem
  -- nunca voltou.
  cadence_days integer check (cadence_days > 0),
  cadence_confidence text not null default 'BAIXA'
    check (cadence_confidence in ('BAIXA', 'MEDIA', 'ALTA')),

  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),

  unique (profile_id, family, label)
);

comment on table app.client_procedures is
  'O que esta cliente faz, quantas vezes fez, e de quanto em quanto tempo volta. A cadência é o que sustenta retorno proativo sem ninguém calcular na mão.';

-- ------------------------------------------------------------- as visitas

-- O histórico de atendimento de verdade: quanto tempo levou e quanto custou.
--
-- Esta tabela é a que faz o agente parar de estimar. O catálogo diz que
-- progressiva leva 3h; a ficha diz que NESTA cliente levou 4h15 e custou 450.
-- Quando as duas discordam, a ficha ganha.
create table if not exists app.client_visits (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references app.tenants(id) on delete cascade,
  profile_id uuid not null references app.client_profiles(id) on delete cascade,

  -- Nulo quando a visita veio do histórico importado, que é anterior ao
  -- sistema. Preenchido quando nasceu de um agendamento daqui.
  appointment_id uuid references app.appointments(id) on delete set null,

  occurred_on  date not null,
  description  text not null,
  family       app.procedure_family,

  -- O que realmente aconteceu, anotado pelo dono. Ambos opcionais: no
  -- histórico antigo quase nunca existem, e uma visita sem valor ainda conta
  -- para a cadência.
  duration_minutes integer check (duration_minutes > 0),
  amount_cents     integer check (amount_cents >= 0),

  notes      text,
  created_at timestamptz not null default statement_timestamp()
);

comment on table app.client_visits is
  'O que aconteceu de verdade, com duração e valor reais. Quando o catálogo e a ficha discordam, a ficha ganha -- ela é medição, o catálogo é estimativa.';

create index if not exists client_visits_por_ficha_idx
  on app.client_visits (tenant_id, profile_id, occurred_on desc);

-- --------------------------------------------------------------- as fotos

create table if not exists app.client_photos (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references app.tenants(id) on delete cascade,
  profile_id uuid not null references app.client_profiles(id) on delete cascade,
  visit_id   uuid references app.client_visits(id) on delete set null,

  -- CABELO_ATUAL é a régua daquela cliente. RESULTADO é como ficou. COR é a
  -- referência do tom que saiu -- o histórico mostra que o tom quase nunca é
  -- anotado em texto (13 fichas em 286), então a foto é o único registro
  -- confiável dele.
  kind text not null check (kind in ('CABELO_ATUAL', 'RESULTADO', 'COR')),

  storage_path text not null,
  caption      text,
  taken_on     date,
  position     integer not null default 0,
  created_at   timestamptz not null default statement_timestamp(),

  unique (tenant_id, storage_path)
);

comment on table app.client_photos is
  'Fotos da cliente guardadas na ficha, com consentimento registrado no perfil. Distintas da foto de conversa, que é classificada e descartada.';

create index if not exists client_photos_por_ficha_idx
  on app.client_photos (tenant_id, profile_id, kind, position);

-- Balde separado do `conhecimento` de propósito. Foto-régua do salão e foto de
-- cliente têm dono, prazo e motivo de apagamento diferentes: a primeira some
-- quando o salão muda a régua, a segunda some quando a cliente pede. Misturar
-- as duas num balde só faria "apagar os dados da fulana" virar uma busca.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('clientes', 'clientes', false, 8388608,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists clientes_le on storage.objects;
drop policy if exists clientes_envia on storage.objects;
drop policy if exists clientes_atualiza on storage.objects;
drop policy if exists clientes_apaga on storage.objects;

create policy clientes_le on storage.objects
  for select to authenticated
  using (bucket_id = 'clientes' and app.storage_folder_is_my_tenant(name));

create policy clientes_envia on storage.objects
  for insert to authenticated
  with check (bucket_id = 'clientes' and app.storage_folder_is_my_tenant(name));

create policy clientes_atualiza on storage.objects
  for update to authenticated
  using (bucket_id = 'clientes' and app.storage_folder_is_my_tenant(name))
  with check (bucket_id = 'clientes' and app.storage_folder_is_my_tenant(name));

create policy clientes_apaga on storage.objects
  for delete to authenticated
  using (bucket_id = 'clientes' and app.storage_folder_is_my_tenant(name));

-- ------------------------------------------------------------- manutenção

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := statement_timestamp();
  return new;
end;
$$;

drop trigger if exists client_profiles_touch on app.client_profiles;
create trigger client_profiles_touch before update on app.client_profiles
  for each row execute function app.touch_updated_at();

drop trigger if exists client_procedures_touch on app.client_procedures;
create trigger client_procedures_touch before update on app.client_procedures
  for each row execute function app.touch_updated_at();

alter table app.client_profiles   enable row level security;
alter table app.client_procedures enable row level security;
alter table app.client_visits     enable row level security;
alter table app.client_photos     enable row level security;
