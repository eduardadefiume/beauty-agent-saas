-- LUZES PRIMEIRO, PROGRESSIVA DEPOIS. E QUAL PROGRESSIVA?
--
-- 15/09, 15:44. A dona testando como cliente:
--
--   ela:     "Qual o valor da progressiva?"
--   agente:  "A progressiva fica R$ 200,00."
--   ela:     "Eu estava querendo fazer um iluminado também, qual eu faço primeiro?"
--   agente:  "Progressiva primeiro, Eduarda, não indico fazer as duas químicas
--             no mesmo período."
--
-- A ordem esta INVERTIDA. No salao e luzes primeiro e progressiva depois --
-- e, de preferencia, a progressiva COM formol, que e a quimica mais
-- compativel com luzes. O agente nao mentiu por conta propria: ele seguiu
-- OFICIO_DUAS_QUIMICAS, que diz para recusar as duas no mesmo dia e marcar em
-- dias separados, e NAO diz qual vem primeiro. Faltando a ordem, ele chutou.
--
-- E antes disso ja faltava outra coisa: "a progressiva" nao existe. Sao cinco
-- neste catalogo (3D, 4D, japonesa, com formol e sem formol). Ninguem
-- perguntou qual ela quer, nem se ela ja fez progressiva antes, nem se a que
-- ela fez tinha formol -- que e o que decide se da para clarear.
--
-- POR QUE ISSO NAO EXISTIA. Quando eu li o arquivo de conversas do salao, eu
-- extrai as PROIBICOES -- nao faca duas quimicas no mesmo dia, nao clareie
-- sobre formol recente, nao prometa tom -- e parei ali. O que um profissional
-- realmente faz, que e a SEQUENCIA (o que vem antes, quanto tempo depois, o
-- que combina com o que, o que oferecer junto), ficou no arquivo. Regra que
-- so proibe deixa o modelo livre para inventar o resto, e foi exatamente isso
-- que aconteceu.
--
-- Isto aqui e conhecimento DO SALAO, entao vai para as policies -- a camada
-- que ganha da camada do produto quando as duas se cruzam.

insert into app.agent_policies (tenant_id, topic, title, body, position)
select t.id, v.topic::app.policy_topic, v.title, v.body, v.position
  from app.tenants t
 cross join (values

  ('PROCEDIMENTO', 'Progressiva: qual delas, e qual ela já fez',
   E'"Progressiva" não é um serviço, é uma família: aqui tem 3D, 4D, japonesa, com formol e sem formol.\n'
   'Então, antes de qualquer valor ou horário, você precisa de DUAS respostas dela, uma pergunta por vez:\n'
   '  1. qual progressiva ela quer — e a diferença que importa para ela é com ou sem formol;\n'
   '  2. se ela já fez progressiva antes e, se já, se tinha formol.\n'
   'A segunda não é curiosidade: formol recente no fio é o que decide se dá para clarear. Sem essa resposta você não sabe o que pode ser feito, e o teste de mecha é quem confirma.',
   8),

  ('PROCEDIMENTO', 'Luzes e progressiva: a ordem, o intervalo e o Violet',
   E'Quando ela quiser luzes (ou mechas, ou iluminado) E progressiva, a ordem é esta, e não é preferência dela nem sua:\n'
   '  LUZES PRIMEIRO. PROGRESSIVA DEPOIS, uma semana depois, no mínimo.\n'
   'E a progressiva indicada nesse caso é a COM FORMOL: é a química mais compatível com cabelo que acabou de receber luzes.\n'
   'O atendimento nesse caso segue nesta sequência:\n'
   '  1. diga a ordem e o porquê, curto: luzes primeiro, progressiva uma semana depois;\n'
   '  2. peça foto do cabelo dela hoje, como ele está;\n'
   '  3. peça a foto de referência, o tom que ela quer;\n'
   '  4. diga os valores dos dois procedimentos;\n'
   '  5. pergunte se ela vai querer fazer os dois.\n'
   'Se ela disser que sim: agende as luzes, e a progressiva para uma semana depois — as duas na mesma conversa, não deixe a segunda "para combinar depois". E ofereça o Violet, que é o tratamento específico para loira.\n'
   'Se ela disser que quer só um: agende o que ela escolheu, sem insistir no outro.',
   9)

 ) as v(topic, title, body, position)
 -- O salao que esta no ar e `piloto-eduarda`. O `salao-do-william` e a semente
 -- antiga, que nao atende ninguem -- e foi para ela que eu escrevi na primeira
 -- tentativa, o que nao deu erro nenhum: a migracao rodou, e a regra nasceu
 -- num tenant que nao conversa com cliente. Escrever no lugar errado e mais
 -- silencioso que nao escrever.
 where t.slug = 'piloto-eduarda'
on conflict do nothing;

-- E a regra de oficio para de parar na proibicao.
--
-- "Nao faca as duas no mesmo dia" sem dizer o que vem primeiro e meia regra:
-- o modelo completa a outra metade sozinho, e completa errado.
update app.agent_prompt_blocks
   set body = body || E'\nE recusar não é a resposta inteira. A cliente que pede duas químicas quer as duas: diga a ORDEM (o que vem primeiro) e o INTERVALO entre elas, e já ofereça os dois horários.\nMas a ordem é decisão TÉCNICA, e ela muda conforme as químicas envolvidas: ela está escrita nas regras deste salão. Se não estiver, você NÃO escolhe por conta própria — pergunte à dona em ownerQuestion, no mesmo atender. Chutar a ordem de duas químicas é estragar o cabelo de alguém com uma frase.'
 where code = 'OFICIO_DUAS_QUIMICAS'
   and body not like '%a ordem é decisão TÉCNICA%';
