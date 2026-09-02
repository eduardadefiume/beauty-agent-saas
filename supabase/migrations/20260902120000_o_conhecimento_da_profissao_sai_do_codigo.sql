-- ETAPA 4: o banco de conhecimento do PRODUTO.
--
-- O PROBLEMA. Hoje o que vale para qualquer salão está misturado com o que é
-- deste salão, e em três lugares diferentes:
--
--   1. `app.seed_color_model` carrega 6 famílias de cor e 9 perguntas dentro
--      do corpo da função. Mudar a pergunta que todo salão vai responder exige
--      migração.
--   2. `app.color_plan` carrega, em texto solto no meio do IF, as frases que
--      explicam por que a descoloração entrou no plano. "Tinta não clareia
--      tinta" é conhecimento de cabeleireiro escrito como literal de plpgsql.
--   3. `app.knowledge_dimensions` não tem base nenhuma: salão novo abre a tela
--      de Conhecimento em branco e o dono digita "Volume" na mão, sem saber o
--      que os outros costumam observar.
--
-- É o mesmo problema que o prompt tinha antes de 20260831120000, e a solução é
-- a mesma: o que é comportamento e dá para escrever em português vira dado.
--
-- A LINHA. Tabela `product_*` não tem tenant_id e é de propósito. É a régua da
-- profissão, igual a `app.tone_levels`: dar a cada salão a sua cópia da regra
-- "tinta não clareia tinta" seria deixar um deles cadastrar que clareia.
-- O salão não edita o produto; o salão edita a CÓPIA que o produto plantou
-- dentro dele, e a coluna `origin` registra que ele mexeu.
--
-- POR QUE `origin` IMPORTA MAIS DO QUE PARECE. Sem ela, "Castanho 3 a 5" que o
-- sistema chutou e "Castanho 3 a 5" que o dono confirmou são a mesma linha, e
-- o onboarding por conversa (etapa 5) não tem como saber o que ainda precisa
-- perguntar. É a diferença entre um cadastro preenchido e um cadastro
-- respondido.

-- ---------------------------------------------------------------------------
-- 1. As regras da profissão
-- ---------------------------------------------------------------------------

create table if not exists app.product_rules (
  code       text primary key,
  subject    text not null check (subject in ('COR', 'QUIMICA', 'CABELO')),
  title      text not null,
  -- A regra como um cabeleireiro a diria. É o que o dono lê na tela e o que o
  -- agente pode citar quando precisa justificar uma etapa.
  statement  text not null,
  -- A frase que entra no campo `porque` do plano, com marcações {niveis},
  -- {tom}, {fundo} e {familia}. Marcação que não existir naquele caso fica
  -- como está: preferi frase feia a plano que estoura por argumento faltando.
  explains   text,
  position   integer not null default 0,
  status     text not null default 'ACTIVE' check (status in ('ACTIVE', 'ARCHIVED')),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp()
);

comment on table app.product_rules is
  'Invariantes da profissão, iguais em qualquer salão. Não tem tenant_id de propósito: quem escolhe se tinta clareia tinta não é o dono do salão.';

insert into app.product_rules (code, subject, title, statement, explains, position) values

('CLAREAMENTO_ACIMA_DO_LIMITE', 'COR',
 'Coloração clareia até certo ponto, depois é descoloração',
 'Coloração levanta poucos níveis em fio virgem. Passado o limite que o salão declara, o clareamento deixa de ser tinta e passa a ser descoloração.',
 'São {niveis} níveis de clareamento, acima do que a coloração daqui clareia sozinha.', 10),

('TINTA_NAO_CLAREIA_TINTA', 'COR',
 'Tinta não clareia tinta',
 'Cabelo que já tem coloração não sobe de tom com mais coloração, por menor que seja o clareamento pedido. Para clarear fio colorido só descolorindo.',
 'O cabelo já é colorido, e tinta não clareia tinta.', 20),

('ESCURECER_SOBRE_DESCOLORIDO', 'COR',
 'Fio descolorido precisa de fundo antes de escurecer',
 'A descoloração tira o pigmento quente do fio. Escurecer por cima do fio vazio entrega cor acinzentada ou esverdeada, que sai na segunda lavagem.',
 'O cabelo está descolorido e vai escurecer: sem repor o fundo, a cor não fixa e esverdeia.', 30),

('QUENTE_SOBRE_DESCOLORIDO', 'COR',
 'Vermelho não fixa em fio vazio',
 'Tom quente precisa de base quente embaixo. Em fio descolorido o vermelho e o acobreado desbotam rápido se o fundo não for reposto antes.',
 'O cabelo está descolorido e o tom pedido é quente: sem repor o fundo, o vermelho não segura.', 40),

('FUNDO_DE_CLAREAMENTO', 'COR',
 'Todo clareamento revela um fundo',
 'Cada altura de tom tem um fundo de clareamento próprio, do vermelho no escuro ao amarelo claro no muito claro. É esse fundo que aparece quando o fio clareia, e é ele que a matização neutraliza.',
 'Clareando até {tom} aparece fundo {fundo}, e é ele que a matização neutraliza.', 50),

('FAMILIA_QUENTE_NAO_MATIZA', 'COR',
 'Em família quente, matizar tira a cor',
 'Ruivo e acobreado vivem do mesmo fundo quente que a matização neutraliza. Matizar nessas famílias apaga justamente o que ia sustentar a cor.',
 'A família {familia} vive do fundo quente, então aqui não entra matização.', 60),

('QUIMICA_NAO_SAI_SOZINHA', 'QUIMICA',
 'Química antiga não vai embora com o tempo',
 'Progressiva, alisamento e relaxamento não desaparecem sozinhos. Saem com o crescimento e com o corte. "Faz dois anos que parei" diz quando a cliente parou, não o que ainda está no fio.',
 null, 70),

('QUIMICA_MUDA_A_COR', 'QUIMICA',
 'Resquício de química muda o resultado da cor',
 'O que sobrou de uma química anterior altera como o fio recebe cor e clareamento. É por isso que existe teste de mecha antes, e não depois.',
 null, 80),

('SO_A_FOTO_DELA_DESCREVE_O_CABELO_DELA', 'CABELO',
 'Foto de inspiração não descreve o cabelo da cliente',
 'A foto que a cliente manda como referência é o resultado que ela quer, e o cabelo ali é de outra pessoa. Só a foto do próprio cabelo dela diz como o cabelo dela é.',
 null, 90),

('DIAGNOSTICO_NAO_SE_PERGUNTA', 'CABELO',
 'Leitura técnica não se pergunta à cliente',
 'Volume, espessura, porosidade e saúde do fio são leitura de quem trabalha com cabelo. Isso se vê na foto ou fica para a avaliação presencial. A cliente procurou o salão justamente para não precisar saber.',
 null, 100)

on conflict (code) do update
  set subject = excluded.subject, title = excluded.title,
      statement = excluded.statement, explains = excluded.explains,
      position = excluded.position, updated_at = statement_timestamp();

-- ---------------------------------------------------------------------------
-- 2. O vocabulário que o salão herda
-- ---------------------------------------------------------------------------

create table if not exists app.product_knowledge_dimensions (
  code            text primary key,
  name            text not null,
  what_to_look_at text,
  position        integer not null default 0,
  -- Dimensão sugerida entra na tela do salão novo; a não sugerida fica de
  -- reserva para o onboarding oferecer quando fizer sentido.
  seeded          boolean not null default true,
  created_at      timestamptz not null default statement_timestamp(),
  updated_at      timestamptz not null default statement_timestamp()
);

create table if not exists app.product_knowledge_options (
  code           text primary key,
  dimension_code text not null references app.product_knowledge_dimensions(code) on delete cascade,
  label          text not null,
  description    text,
  position       integer not null default 0,
  created_at     timestamptz not null default statement_timestamp(),
  updated_at     timestamptz not null default statement_timestamp(),
  unique (dimension_code, label)
);

comment on table app.product_knowledge_dimensions is
  'O que salões costumam observar numa foto. É ponto de partida, não imposição: o salão renomeia, redefine ou apaga o que herdou.';
comment on column app.product_knowledge_options.description is
  'A definição neutra do produto. Vale enquanto o dono não escrever a dele, porque "médio" é fronteira e fronteira muda de salão para salão.';

insert into app.product_knowledge_dimensions (code, name, what_to_look_at, position, seeded) values
  ('COMPRIMENTO', 'Comprimento',
   'Onde a ponta do cabelo termina em relação ao corpo: queixo, ombro, meio das costas.', 10, true),
  ('ESPESSURA', 'Espessura do fio',
   'A grossura de um fio sozinho, não a quantidade de cabelo.', 20, true),
  ('VOLUME', 'Volume',
   'Quanto o cabelo ocupa de espaço: quantidade de fios somada à abertura da massa.', 30, true),
  ('CURVATURA', 'Curvatura',
   'O desenho do fio: liso, ondulado, cacheado ou crespo.', 40, true),
  ('ESTADO_DO_FIO', 'Estado do fio',
   'Brilho, ponta e uniformidade. Sinal de dano aparece na ponta e no meio antes da raiz.', 50, false)
on conflict (code) do update
  set name = excluded.name, what_to_look_at = excluded.what_to_look_at,
      position = excluded.position, seeded = excluded.seeded,
      updated_at = statement_timestamp();

insert into app.product_knowledge_options (code, dimension_code, label, description, position) values
  ('COMPRIMENTO_CURTO',  'COMPRIMENTO', 'Curto',  'Termina acima do ombro.', 10),
  ('COMPRIMENTO_MEDIO',  'COMPRIMENTO', 'Médio',  'Entre o ombro e a altura do sutiã.', 20),
  ('COMPRIMENTO_LONGO',  'COMPRIMENTO', 'Longo',  'Passa da altura do sutiã.', 30),

  ('ESPESSURA_FINO',     'ESPESSURA', 'Fino',    'Fio de pouca resistência, que a química atravessa rápido.', 10),
  ('ESPESSURA_MEDIO',    'ESPESSURA', 'Médio',   'O fio mais comum, sem resistência nem fragilidade marcada.', 20),
  ('ESPESSURA_GROSSO',   'ESPESSURA', 'Grosso',  'Fio de diâmetro largo, que costuma pedir mais tempo de processo.', 30),

  ('VOLUME_POUCO',       'VOLUME', 'Pouco',   'Cabelo que assenta sozinho e ocupa pouco espaço.', 10),
  ('VOLUME_MEDIO',       'VOLUME', 'Médio',   'Abre um pouco, mas continua acompanhando o formato da cabeça.', 20),
  ('VOLUME_MUITO',       'VOLUME', 'Muito',   'Massa que abre bastante e ocupa espaço bem além do contorno da cabeça.', 30),

  ('CURVATURA_LISO',     'CURVATURA', 'Liso',      'Sem onda desenhada, do comprimento à ponta.', 10),
  ('CURVATURA_ONDULADO', 'CURVATURA', 'Ondulado',  'Onda aberta, em S, sem cacho fechado.', 20),
  ('CURVATURA_CACHEADO', 'CURVATURA', 'Cacheado',  'Cacho desenhado e fechado, com espiral visível.', 30),
  ('CURVATURA_CRESPO',   'CURVATURA', 'Crespo',    'Curvatura muito fechada, em ziguezague, com pouco desenho de espiral.', 40),

  ('ESTADO_SAUDAVEL',    'ESTADO_DO_FIO', 'Saudável',   'Brilho uniforme e ponta inteira.', 10),
  ('ESTADO_RESSECADO',   'ESTADO_DO_FIO', 'Ressecado',  'Sem brilho, áspero ao toque, mas ainda com corpo.', 20),
  ('ESTADO_DANIFICADO',  'ESTADO_DO_FIO', 'Danificado', 'Ponta aberta, elasticidade perdida, quebra ao pentear.', 30)
on conflict (code) do update
  set dimension_code = excluded.dimension_code, label = excluded.label,
      description = excluded.description, position = excluded.position,
      updated_at = statement_timestamp();

-- ---------------------------------------------------------------------------
-- 3. O modelo de cor sai de dentro da função
-- ---------------------------------------------------------------------------

create table if not exists app.product_tone_families (
  code            text primary key,
  name            text not null,
  description     text,
  min_level       smallint references app.tone_levels(level),
  max_level       smallint references app.tone_levels(level),
  needs_warm_base boolean not null default false,
  position        integer not null default 0,
  created_at      timestamptz not null default statement_timestamp(),
  updated_at      timestamptz not null default statement_timestamp()
);

comment on table app.product_tone_families is
  'As famílias que quase todo salão tem, com faixa de partida. A faixa aqui é chute do produto: quando o salão sobe foto, quem manda é a foto.';

create table if not exists app.product_color_questions (
  key             text primary key,
  question        text not null,
  helper          text,
  unit            text not null check (unit in ('NIVEIS', 'MINUTOS', 'REAIS', 'SIM_NAO')),
  suggested_value numeric not null,
  position        integer not null default 0,
  created_at      timestamptz not null default statement_timestamp(),
  updated_at      timestamptz not null default statement_timestamp()
);

comment on table app.product_color_questions is
  'As perguntas de cor que o produto faz a todo dono. A resposta é dele; a pergunta e a sugestão são do produto.';

insert into app.product_tone_families (code, name, description, min_level, max_level, needs_warm_base, position) values
  ('CASTANHO',  'Castanho',  'Tons de castanho, do escuro ao claro.',       3,  5, false, 1),
  ('CHOCOLATE', 'Chocolate', 'Castanho com reflexo quente, mais fechado.',  4,  6, false, 2),
  ('RUIVO',     'Ruivo',     'Acobreados e avermelhados.',                  5,  8, true,  3),
  ('ILUMINADO', 'Iluminado', 'Morena iluminada: luz sem sair do castanho.', 6,  8, false, 4),
  ('LOIRO',     'Loiro',     'Do louro escuro ao louro claro.',             7,  9, false, 5),
  ('PLATINADO', 'Platinado', 'Louro muito claro e acinzentado.',            9, 10, false, 6)
on conflict (code) do update
  set name = excluded.name, description = excluded.description,
      min_level = excluded.min_level, max_level = excluded.max_level,
      needs_warm_base = excluded.needs_warm_base, position = excluded.position,
      updated_at = statement_timestamp();

insert into app.product_color_questions (key, question, helper, unit, suggested_value, position) values
  ('CLAREIA_SEM_DESCOLORIR',
   'Até quantos níveis a coloração daqui clareia sem precisar descolorir?',
   'Na maioria dos salões a tinta clareia até 2 níveis em cabelo virgem. Acima disso, descoloração.',
   'NIVEIS', 2, 1),
  ('TESTE_A_PARTIR_DE',
   'A partir de quantos níveis de clareamento você exige teste de mecha?',
   'O teste responde até que tom o fio chega e se ele aguenta. Quanto maior o clareamento, mais ele importa.',
   'NIVEIS', 3, 2),
  ('MINUTOS_POR_NIVEL',
   'Quantos minutos a mais cada nível clareado leva?',
   'Some só o tempo extra do clareamento, não o procedimento inteiro.',
   'MINUTOS', 30, 3),
  ('REAIS_POR_NIVEL',
   'Quanto a mais você cobra por cada nível clareado?',
   'Em reais. Deixe 0 se o preço não muda com o clareamento.',
   'REAIS', 0, 4),
  ('MINUTOS_PRE_PIGMENTACAO',
   'Quantos minutos leva a pré-pigmentação?',
   'A pré-pigmentação repõe o fundo que o clareamento tirou, antes de escurecer.',
   'MINUTOS', 40, 5),
  ('REAIS_PRE_PIGMENTACAO',
   'Quanto custa a pré-pigmentação?',
   'Em reais. Deixe 0 se já está incluso no procedimento.',
   'REAIS', 0, 6),
  ('MINUTOS_MATIZACAO',
   'Quantos minutos leva a matização?',
   'A matização neutraliza o fundo que aparece no clareamento.',
   'MINUTOS', 30, 7),
  ('REAIS_MATIZACAO',
   'Quanto custa a matização?',
   'Em reais. Deixe 0 se já está incluso no procedimento.',
   'REAIS', 0, 8),
  ('QUIMICA_EXIGE_TESTE',
   'Cabelo com química antiga sempre faz teste de mecha antes de cor?',
   'Progressiva e alisamento não saem sozinhos com o tempo; o resquício muda o resultado da cor.',
   'SIM_NAO', 1, 9)
on conflict (key) do update
  set question = excluded.question, helper = excluded.helper,
      unit = excluded.unit, suggested_value = excluded.suggested_value,
      position = excluded.position, updated_at = statement_timestamp();
