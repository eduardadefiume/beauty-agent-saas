-- O CORTE ENTRA NA REGUA.
--
-- 24/09/2026. A dona decidiu: corte e uma dimensao da regua, com opcoes e com
-- foto -- nao so uma regra de texto. A regua ja tinha Comprimento, Curvatura,
-- Espessura e Volume, que dizem como o cabelo E; nenhuma dizia que FORMA ele
-- tem. Sem isso, a foto de um pixie que o dono manda nao tem onde cair, e a
-- atendente nao reconhece um pixie na foto da cliente.
--
-- A regua e VOCABULARIO: "isto e um pixie". Se o salao faz ou nao faz um corte
-- e outra coisa, e vai para a regra da atendente (eddy_criar_regra). Assim a
-- mesma regua serve para ler a foto da propria cliente, que ninguem pergunta
-- se o salao faz.
--
-- As opcoes sao o ponto de partida do produto. O dono renomeia, acrescenta
-- ("corte borboleta") e arquiva o que nao usa, como nas outras dimensoes.

insert into app.product_knowledge_dimensions (code, name, what_to_look_at, position, seeded) values
  ('CORTE', 'Corte',
   'A forma do corte: onde as pontas terminam, se tem camadas, se a frente é mais comprida que a nuca, se tem franja. Não é o comprimento: um long bob e um chanel podem ter o mesmo comprimento e cortes diferentes.',
   15, true)
on conflict (code) do nothing;

insert into app.product_knowledge_options (code, dimension_code, label, description, position) values
  ('CORTE_PIXIE',          'CORTE', 'Pixie (joãozinho)', 'Bem curto, nuca e laterais rentes, volume no topo.', 10),
  ('CORTE_CHANEL',         'CORTE', 'Chanel',            'Reto, na altura do queixo, pontas alinhadas.', 20),
  ('CORTE_CHANEL_DE_BICO', 'CORTE', 'Chanel de bico',    'Mais curto na nuca e mais comprido na frente.', 30),
  ('CORTE_LONG_BOB',       'CORTE', 'Long bob',          'Entre o queixo e o ombro, reto ou levemente desfiado.', 40),
  ('CORTE_RETO',           'CORTE', 'Reto',              'Pontas todas na mesma altura, sem camadas.', 50),
  ('CORTE_CAMADAS',        'CORTE', 'Em camadas',        'Comprimentos diferentes que dão movimento, sem repicar as pontas.', 60),
  ('CORTE_REPICADO',       'CORTE', 'Repicado',          'Pontas desfiadas e irregulares, aspecto leve.', 70),
  ('CORTE_SHAG',           'CORTE', 'Shag / mullet',     'Muitas camadas curtas no topo, franja, nuca mais longa.', 80)
on conflict (code) do nothing;

-- Os saloes que ja existem. seed_tenant_knowledge so cria dimensao para salao
-- que ainda nao tem nenhuma, entao os quatro de hoje nunca receberiam o Corte
-- sem isto. Salao novo recebe pelo seed, porque a dimensao nasce seeded.
insert into app.knowledge_dimensions
  (tenant_id, name, what_to_look_at, position, origin, product_code)
select t.id, d.name, d.what_to_look_at, d.position, 'PRODUTO', d.code
  from app.tenants t
  cross join app.product_knowledge_dimensions d
 where d.code = 'CORTE'
   and not exists (
     select 1 from app.knowledge_dimensions k
      where k.tenant_id = t.id and (k.product_code = 'CORTE' or lower(k.name) = 'corte')
   )
on conflict (tenant_id, name) do nothing;

insert into app.knowledge_options
  (tenant_id, dimension_id, label, description, position, origin, product_code)
select k.tenant_id, k.id, o.label, o.description, o.position, 'PRODUTO', o.code
  from app.knowledge_dimensions k
  join app.product_knowledge_options o on o.dimension_code = 'CORTE'
 where k.product_code = 'CORTE'
on conflict (dimension_id, label) do nothing;
