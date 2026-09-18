-- O modelo de cor: eu monto a estrutura inteira, o William só responde.
--
-- A PERGUNTA DA DUDA, inteira: "Como vamos fazer pra cadastrar valor em tons?
-- Hoje é iluminado, loiro, mas tem os ruivos que mudam um pouco, como o agente
-- vai saber que tal tom se encaixa em iluminado, qual tom se encaixa em ruivo,
-- quais tons se encaixam em loiro, quais tons e em quais tons do cabelo da
-- cliente precisa de pré pigmentação, modificar o fundo da cor do cabelo para
-- atingir a cor que ela quer?"
--
-- E a decisão dela: "Quem responde as perguntas de cor é o william, mas monta
-- toda a estrutura para que ele só responda."
--
-- ---------------------------------------------------------------------------
-- O ERRO QUE EU QUASE COMETI, e por que a forma desta tabela é esta.
--
-- O desenho óbvio é uma tabela de decisão: uma linha por caso. Só que os casos
-- são (nível de origem 1..10) x (nível de destino 1..10) x (estado do fio) x
-- (família de tom) -- centenas de linhas. "O William só responde" viraria o
-- William respondendo quatrocentas perguntas, que é exatamente o cadastro na
-- mão que a Duda disse que não quer.
--
-- A saída é separar o que é conta do que é decisão de negócio.
--
--   CONTA é universal e não se pergunta a ninguém: quantos níveis faltam
--   clarear, qual fundo aparece quando se clareia até ali, se tinta sobre tinta
--   clareia (não clareia), se escurecer um cabelo descolorido pede
--   pré-pigmentação (pede, senão a cor não fixa e esverdeia). Isso é teoria de
--   coloração, vale em Ribeirão Preto e em qualquer lugar, e vira código.
--
--   DECISÃO DE NEGÓCIO é o que muda de salão para salão, e são POUCAS
--   perguntas: até quantos níveis a coloração daqui clareia sem descolorir, a
--   partir de quantos níveis se exige teste de mecha, quanto tempo e quanto
--   dinheiro cada nível a mais custa. Isso é o que o William responde -- oito
--   perguntas, não quatrocentas.
--
-- Cada pergunta nasce com uma sugestão minha JÁ PREENCHIDA, para o sistema
-- funcionar desde o primeiro dia, e com a resposta dele vazia ao lado. E o
-- plano sempre diz de qual das duas cada número veio. Apresentar sugestão
-- minha como resposta do dono seria o jeito mais rápido de ele confiar numa
-- conta que ele nunca conferiu.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. A escala de altura de tom. GLOBAL: não tem tenant_id.
--
-- Não é vocabulário de salão, é a régua da profissão -- 1 é preto, 10 é louro
-- clarísssimo, e todo colorista do mundo usa a mesma. Dar a cada salão a sua
-- cópia seria deixar um deles cadastrar que 3 é mais claro que 8.
--
-- A coluna que importa é `underlying_pigment`: o FUNDO DE CLAREAMENTO, o
-- pigmento que aparece quando o fio é clareado até aquela altura. É a resposta
-- literal ao "modificar o fundo da cor do cabelo para atingir a cor que ela
-- quer" da Duda: é contra esse fundo que a matização trabalha, e é ele que
-- explica por que um cabelo clareado até 7 fica laranja se ninguém matizar.
-- ---------------------------------------------------------------------------
create table if not exists app.tone_levels (
  level              smallint primary key check (level between 1 and 10),
  name               text not null,
  underlying_pigment text not null
);

comment on table app.tone_levels is
  'A escala de altura de tom, de 1 (preto) a 10 (louro clarissimo). GLOBAL de proposito: e a regua da profissao, nao vocabulario de salao. underlying_pigment e o fundo de clareamento que aparece ao clarear ate aquela altura -- e contra ele que a matizacao trabalha.';

insert into app.tone_levels (level, name, underlying_pigment) values
  (1,  'Preto',                 'nenhum -- o fio ainda não foi clareado'),
  (2,  'Castanho muito escuro', 'vermelho'),
  (3,  'Castanho escuro',       'vermelho'),
  (4,  'Castanho médio',        'vermelho-alaranjado'),
  (5,  'Castanho claro',        'laranja-avermelhado'),
  (6,  'Louro escuro',          'laranja'),
  (7,  'Louro médio',           'laranja-amarelado'),
  (8,  'Louro claro',           'amarelo-alaranjado'),
  (9,  'Louro muito claro',     'amarelo'),
  (10, 'Louro claríssimo',      'amarelo claro')
on conflict (level) do nothing;

-- ---------------------------------------------------------------------------
-- 2. As famílias de tom que ESTE salão vende.
--
-- É aqui que mora a pergunta "qual tom se encaixa em ruivo, qual em loiro".
-- A resposta não é uma lista minha de tons: é a faixa de altura que cada
-- família cobre neste salão, escrita pelo dono. "Loiro" num salão pode começar
-- no 7 e em outro no 8, e os dois estão certos.
--
-- `needs_warm_base` existe porque ruivo e acobreado são a exceção que quebra a
-- regra do resto: neles o fundo alaranjado do clareamento é aliado, não
-- inimigo. Clarear demais antes de um ruivo é tirar justamente o que vai
-- sustentar a cor.
-- ---------------------------------------------------------------------------
create table if not exists app.tone_families (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references app.tenants(id) on delete cascade,
  name        text not null,
  description text,
  min_level   smallint references app.tone_levels(level),
  max_level   smallint references app.tone_levels(level),
  needs_warm_base boolean not null default false,
  -- O que ESTA família cobra e demora a mais, além da conta de clareamento.
  extra_minutes     integer,
  extra_price_minor integer,
  position    integer not null default 0,
  status      text not null default 'ACTIVE' check (status in ('ACTIVE', 'ARCHIVED')),
  -- Nulo enquanto for sugestão minha. Preenchido quando uma pessoa confirma.
  answered_at timestamptz,
  answered_by text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create index if not exists tone_families_tenant_idx on app.tone_families (tenant_id, position);
alter table app.tone_families enable row level security;

comment on table app.tone_families is
  'As familias de tom que ESTE salao vende, e a faixa de altura de tom que cada uma cobre aqui. answered_at nulo significa que a linha ainda e sugestao do sistema, nao resposta do dono.';
comment on column app.tone_families.needs_warm_base is
  'Ruivo e acobreado sustentam a cor no fundo quente do clareamento. Clarear demais antes deles tira o que ia segurar a cor.';

-- ---------------------------------------------------------------------------
-- 3. As oito perguntas que o dono responde.
--
-- `suggested_value` é minha, `answer_value` é dele. O plano usa a resposta
-- quando existe e a sugestão quando não existe, e sempre diz qual das duas
-- usou.
-- ---------------------------------------------------------------------------
create table if not exists app.color_policies (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references app.tenants(id) on delete cascade,
  key             text not null,
  question        text not null,
  helper          text,
  unit            text not null check (unit in ('NIVEIS', 'MINUTOS', 'REAIS', 'SIM_NAO')),
  suggested_value numeric not null,
  answer_value    numeric,
  answered_at     timestamptz,
  answered_by     text,
  position        integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, key)
);

create index if not exists color_policies_tenant_idx on app.color_policies (tenant_id, position);
alter table app.color_policies enable row level security;

comment on table app.color_policies is
  'As poucas perguntas de cor que mudam de salao para salao. suggested_value e a sugestao do sistema, answer_value e a resposta do dono. O plano diz sempre de qual das duas cada numero veio.';

-- ---------------------------------------------------------------------------
-- 4. Semear a estrutura para um salão.
--
-- Idempotente de propósito, e por um motivo específico: ela vai ser chamada de
-- novo pelo onboarding por conversa. Rodar duas vezes não pode apagar o que o
-- dono já respondeu.
-- ---------------------------------------------------------------------------
create or replace function app.seed_color_model(p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_familias integer := 0;
  v_perguntas integer := 0;
begin
  insert into app.tone_families
    (tenant_id, name, description, min_level, max_level, needs_warm_base, position)
  values
    (p_tenant_id, 'Castanho',  'Tons de castanho, do escuro ao claro.',            3,  5, false, 1),
    (p_tenant_id, 'Chocolate', 'Castanho com reflexo quente, mais fechado.',       4,  6, false, 2),
    (p_tenant_id, 'Ruivo',     'Acobreados e avermelhados.',                        5,  8, true,  3),
    (p_tenant_id, 'Iluminado', 'Morena iluminada: luz sem sair do castanho.',       6,  8, false, 4),
    (p_tenant_id, 'Loiro',     'Do louro escuro ao louro claro.',                   7,  9, false, 5),
    (p_tenant_id, 'Platinado', 'Louro muito claro e acinzentado.',                  9, 10, false, 6)
  on conflict (tenant_id, name) do nothing;
  get diagnostics v_familias = row_count;

  insert into app.color_policies
    (tenant_id, key, question, helper, unit, suggested_value, position)
  values
    (p_tenant_id, 'CLAREIA_SEM_DESCOLORIR',
     'Até quantos níveis a coloração daqui clareia sem precisar descolorir?',
     'Na maioria dos salões a tinta clareia até 2 níveis em cabelo virgem. Acima disso, descoloração.',
     'NIVEIS', 2, 1),
    (p_tenant_id, 'TESTE_A_PARTIR_DE',
     'A partir de quantos níveis de clareamento você exige teste de mecha?',
     'O teste responde até que tom o fio chega e se ele aguenta. Quanto maior o clareamento, mais ele importa.',
     'NIVEIS', 3, 2),
    (p_tenant_id, 'MINUTOS_POR_NIVEL',
     'Quantos minutos a mais cada nível clareado leva?',
     'Some só o tempo extra do clareamento, não o procedimento inteiro.',
     'MINUTOS', 30, 3),
    (p_tenant_id, 'REAIS_POR_NIVEL',
     'Quanto a mais você cobra por cada nível clareado?',
     'Em reais. Deixe 0 se o preço não muda com o clareamento.',
     'REAIS', 0, 4),
    (p_tenant_id, 'MINUTOS_PRE_PIGMENTACAO',
     'Quantos minutos leva a pré-pigmentação?',
     'A pré-pigmentação repõe o fundo que o clareamento tirou, antes de escurecer.',
     'MINUTOS', 40, 5),
    (p_tenant_id, 'REAIS_PRE_PIGMENTACAO',
     'Quanto custa a pré-pigmentação?',
     'Em reais. Deixe 0 se já está incluso no procedimento.',
     'REAIS', 0, 6),
    (p_tenant_id, 'MINUTOS_MATIZACAO',
     'Quantos minutos leva a matização?',
     'A matização neutraliza o fundo que aparece no clareamento.',
     'MINUTOS', 30, 7),
    (p_tenant_id, 'REAIS_MATIZACAO',
     'Quanto custa a matização?',
     'Em reais. Deixe 0 se já está incluso no procedimento.',
     'REAIS', 0, 8),
    (p_tenant_id, 'QUIMICA_EXIGE_TESTE',
     'Cabelo com química antiga sempre faz teste de mecha antes de cor?',
     'Progressiva e alisamento não saem sozinhos com o tempo; o resquício muda o resultado da cor.',
     'SIM_NAO', 1, 9)
  on conflict (tenant_id, key) do nothing;
  get diagnostics v_perguntas = row_count;

  return jsonb_build_object(
    'ok', true, 'familiasCriadas', v_familias, 'perguntasCriadas', v_perguntas
  );
end;
$function$;

revoke all on function app.seed_color_model(uuid) from public, anon, authenticated;
grant execute on function app.seed_color_model(uuid) to service_role;

-- Todo salão que já existe recebe a estrutura agora. Salão novo recebe pelo
-- onboarding.
do $$
declare v_tenant uuid;
begin
  for v_tenant in select id from app.tenants loop
    perform app.seed_color_model(v_tenant);
  end loop;
end $$;
