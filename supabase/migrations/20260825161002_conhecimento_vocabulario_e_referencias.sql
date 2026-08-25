-- Módulo Conhecimento: ensinar ao agente como é o cabelo desta cliente.
--
-- O PROBLEMA. Uma progressiva em cabelo curto e uma em cabelo longo são o
-- mesmo serviço com duração e preço diferentes. Isso já existe como "variação"
-- dentro de cada serviço (texto livre + preço). O que falta é o agente saber
-- DECIDIR qual variação vale quando a cliente manda uma foto — hoje ele
-- pergunta à dona, e é esse tipo de pergunta repetida que cansa o dono.
--
-- POR QUE ISTO NÃO MORA DENTRO DA CONFIGURAÇÃO. Duas razões, a segunda decisiva:
--
-- 1. "Cabelo longo" não é propriedade do serviço, é propriedade do cabelo da
--    cliente. O mesmo comprimento vale para progressiva, mechas e corte. Hoje
--    está repetido como variação em cada serviço; o vocabulário real é do
--    salão inteiro.
--
-- 2. As tabelas de configuração são clonadas a cada publicação, com ids novos.
--    Conhecimento amarrado a um variation_id viraria órfão toda vez que a Duda
--    publicasse — e as fotos de referência, que dão trabalho para juntar,
--    sumiriam junto. Aqui as referências pertencem ao TENANT e sobrevivem.
--
-- A ponte com o que já existe é `service_variations.classification_values`,
-- coluna jsonb que estava criada e sem uso: uma variação pode declarar
-- {"<dimension_id>": "<option_id>"} e, a partir daí, uma foto classificada
-- escolhe a variação sozinha. Variação sem essa ponte continua como hoje.

create table if not exists app.knowledge_dimensions (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references app.tenants(id) on delete cascade,
  name       text not null,
  -- O que a dona quer que seja observado na foto. Vira instrução para o
  -- classificador, então é texto de gente.
  what_to_look_at text,
  position   integer not null default 0,
  status     text not null default 'ACTIVE' check (status in ('ACTIVE', 'ARCHIVED')),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  unique (tenant_id, name)
);

comment on table app.knowledge_dimensions is
  'O que este salão observa numa foto para decidir duração e preço (ex.: Comprimento, Volume). Pertence ao tenant, não à configuração — sobrevive a publicações.';

create table if not exists app.knowledge_options (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  dimension_id uuid not null references app.knowledge_dimensions(id) on delete cascade,
  label        text not null,
  -- A definição EM PALAVRAS, escrita pela dona. É o que mais pesa: "médio"
  -- varia de salão para salão, e foto sozinha não diz onde está a fronteira.
  description  text,
  position     integer not null default 0,
  status       text not null default 'ACTIVE' check (status in ('ACTIVE', 'ARCHIVED')),
  created_at   timestamptz not null default statement_timestamp(),
  updated_at   timestamptz not null default statement_timestamp(),
  unique (dimension_id, label)
);

comment on table app.knowledge_options is
  'Cada valor possível de uma dimensão (Curto, Médio, Longo), com a definição escrita pela dona. A descrição pesa mais que a foto: "médio" é fronteira, e fronteira se explica com palavras.';

create table if not exists app.knowledge_reference_photos (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  option_id    uuid not null references app.knowledge_options(id) on delete cascade,
  storage_path text not null,
  caption      text,
  position     integer not null default 0,
  created_at   timestamptz not null default statement_timestamp(),
  unique (tenant_id, storage_path)
);

comment on table app.knowledge_reference_photos is
  'Fotos que o salão usa como régua para cada opção. São fotos do próprio salão, não de clientes em atendimento.';

create index if not exists knowledge_options_por_dimensao_idx
  on app.knowledge_options (tenant_id, dimension_id, position);
create index if not exists knowledge_reference_photos_por_opcao_idx
  on app.knowledge_reference_photos (tenant_id, option_id, position);

-- Balde privado. Foto de referência não é pública: quem vê é quem tem sessão
-- no configurador, por URL assinada e temporária.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('conhecimento', 'conhecimento', false, 8388608,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
