-- A família de tom passa a ser definida por FOTO, não por número.
--
-- A CORREÇÃO DA DUDA, e ela está certa: "não é número que vai dizer qual a
-- família da cor e sim foto, ele vai subir fotos e dizer qual a classe de cor
-- ele pertence."
--
-- O QUE EU TINHA FEITO ERRADO. Eu pedia ao William "de qual altura de tom até
-- qual altura de tom vai o Ruivo?". Isso é pedir que um cabeleireiro traduza o
-- ofício dele para uma escala numérica antes de poder responder. Ele não pensa
-- assim, e nem precisa: ele olha uma foto e sabe na hora se aquilo é ruivo, se
-- é morena iluminada ou se é loiro. A pergunta certa é a que usa a linguagem
-- dele, e a linguagem dele é imagem.
--
-- O NÚMERO NÃO SOME -- ele muda de dono. A conta de clareamento precisa de
-- altura de tom para existir (quantos níveis faltam, qual fundo aparece). Só
-- que agora ela vem de LER a foto, não de o William digitar. Ele sobe a foto e
-- diz a classe; o sistema lê a altura. Se a leitura sair errada, ele corrige --
-- mas corrigir é a exceção, não o caminho.
--
-- Por isso a faixa da família deixa de ser um campo de formulário e passa a ser
-- CONSEQUÊNCIA das fotos que ele classificou. Uma família com fotos de altura 5
-- a 8 é uma família que vai de 5 a 8, e ninguém precisou digitar isso.

create table if not exists app.tone_family_photos (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  family_id    uuid not null references app.tone_families(id) on delete cascade,
  storage_path text not null,
  caption      text,
  -- Lida da foto pelo motor, corrigível por gente. Nunca digitada como
  -- primeiro caminho: é isso que distingue este desenho do anterior.
  estimated_level smallint references app.tone_levels(level),
  level_source text check (level_source in ('LIDO_NA_FOTO', 'PESSOA')),
  read_at      timestamptz,
  read_error   text,
  read_attempts integer not null default 0,
  position     integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, storage_path)
);

create index if not exists tone_family_photos_por_familia_idx
  on app.tone_family_photos (tenant_id, family_id, position);
-- A fila do leitor: foto sem altura lida e com tentativa sobrando.
create index if not exists tone_family_photos_por_ler_idx
  on app.tone_family_photos (tenant_id)
  where estimated_level is null and read_attempts < 3;

alter table app.tone_family_photos enable row level security;

comment on table app.tone_family_photos is
  'As fotos com que o dono ensina o que e cada familia de tom neste salao. E o vocabulario de cor dele, em imagem. A altura de tom de cada foto e LIDA pelo motor, nao digitada.';
comment on column app.tone_family_photos.estimated_level is
  'Altura de tom lida nesta foto. E dela que sai a faixa da familia -- ninguem digita faixa.';
comment on column app.tone_family_photos.level_source is
  'LIDO_NA_FOTO quando o motor leu, PESSOA quando alguem corrigiu. Correcao de gente nunca e sobrescrita pelo motor.';

-- ---------------------------------------------------------------------------
-- A faixa da família é o que as fotos dela dizem.
--
-- Enquanto não houver foto lida, cai no que estiver nas colunas -- que hoje é a
-- sugestão que eu semeei. É melhor que nada: o sistema funciona no primeiro dia
-- e vai ficando do salão à medida que ele sobe foto.
-- ---------------------------------------------------------------------------
create or replace function app.tone_family_range(p_family_id uuid)
returns table (min_level smallint, max_level smallint, from_photos boolean)
language sql
stable
security definer
set search_path to ''
as $function$
  select
    coalesce(f.das_fotos_min, t.min_level),
    coalesce(f.das_fotos_max, t.max_level),
    f.das_fotos_min is not null
  from app.tone_families t
  left join lateral (
    select min(p.estimated_level)::smallint as das_fotos_min,
           max(p.estimated_level)::smallint as das_fotos_max
      from app.tone_family_photos p
     where p.family_id = t.id and p.estimated_level is not null
  ) f on true
  where t.id = p_family_id;
$function$;

revoke all on function app.tone_family_range(uuid) from public, anon, authenticated;
grant execute on function app.tone_family_range(uuid) to service_role;

comment on function app.tone_family_range(uuid) is
  'A faixa de altura de tom de uma familia, tirada das fotos que o dono classificou. Cai na coluna so enquanto nao houver foto lida.';
