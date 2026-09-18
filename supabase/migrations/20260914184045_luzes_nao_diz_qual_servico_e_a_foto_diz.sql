-- "LUZES" NAO DIZ QUAL SERVICO E. A FOTO DIZ.
--
-- Teste real de 14/09. A cliente perguntou "qual o valor para luzes?". O
-- catalogo deste salao nao tem nenhum servico chamado "Luzes" -- tem "Mechas
-- loiras" (R$ 450) e "Mechas morena iluminada" (R$ 420). O agente escolheu
-- morena iluminada, respondeu o valor da arte e reservou a agenda desse
-- servico. Pode ter acertado; foi no chute.
--
-- A proprietaria nomeou o problema melhor do que eu: "a maioria so diz luzes,
-- mas nao diz se e iluminado ou loiro. O agente e que tem que saber quando ela
-- mandar a foto". Ou seja: a palavra da cliente e ambigua por natureza, e quem
-- desfaz a ambiguidade e a imagem -- exatamente como um cabeleireiro faz.
--
-- Isso e conhecimento de COR, e ele se divide nas duas camadas que arrumamos
-- hoje de manha:
--
--   OFICIO (estes dois blocos, camada do produto): o vocabulario. O que
--   "luzes", "balayage", "morena iluminada" e "loiro global" querem dizer, e
--   qual e o sinal na foto que separa um do outro -- olhar a raiz e o fundo.
--   Isso e igual em qualquer salao do Brasil.
--
--   SALAO (o campo `description` de cada servico do catalogo): quais dos MEUS
--   servicos correspondem a cada caso, e como as minhas clientes chamam eles.
--   Isso e do dono, muda de casa para casa, e ele edita na tela.
--
-- O campo `description` ja existe e ja chega ao agente no contexto; hoje esta
-- null em todos os servicos de cor. Nao precisa de tabela nova nem de coluna
-- nova: precisa que a dona escreva.
--
-- E a regra que fecha o buraco: quando dois servicos cabem e a foto nao
-- resolve, o agente faz UMA pergunta que separa os dois. Nao escolhe no chute,
-- e nao devolve um menu de precos. Preco de um servico com a agenda de outro e
-- o erro que so aparece na cadeira.

insert into app.agent_prompt_blocks (code, title, body, position, status) values

('OFICIO_VOCABULARIO_DE_COR', 'O que a cliente chama de "luzes"',
$b$O QUE A CLIENTE CHAMA DE "LUZES"
Quase ninguém pede o nome do serviço. Pede o resultado, e quase sempre com uma palavra só: "luzes", "mechas", "queria clarear". Essa palavra NÃO diz qual serviço é, e serviços de cor diferentes têm preço e tempo diferentes. Marcar o errado é mandar a cliente para o procedimento errado.
O que as palavras costumam querer dizer:
  LUZES / MECHAS / BABYLIGHTS: clarear em fios separados, mantendo o fundo. Quanto do fundo fica é o que muda tudo.
  MORENA ILUMINADA / MORENA CHIC: o fundo escuro FICA, e a luz vem em fios finos e no contorno do rosto. Continua morena, só iluminada.
  BALAYAGE / OMBRÉ / MECHAS ESFUMADAS: clareado pintado à mão, raiz preservada, transição suave. Menos manutenção, porque a raiz não marca.
  LOIRO / PLATINADO / GLOBAL: clarear o cabelo inteiro, raiz junto. É o que mais exige do fio e o que mais pede manutenção.
  GLOSS / TONALIZANTE / MATIZAÇÃO: não clareia, ajusta o tom do que já está claro.
Na FOTO de referência, o que separa os casos é uma coisa só: OLHE A RAIZ E O FUNDO. Fundo escuro mantido com fios claros por cima é iluminada ou balayage. Raiz clara igual ao comprimento é loiro global. Essa leitura é sua, e é ela que decide de qual serviço você está falando.$b$, 480, 'ACTIVE'),

('OFICIO_QUAL_SERVICO_E_ESSE', 'Casar o que ela quer com o serviço do catálogo',
$b$CASAR O QUE ELA QUER COM O SERVIÇO DO CATÁLOGO
O catálogo é a lista do que ESTE salão vende, e `description` é onde a dona explica quando cada serviço se aplica e como as clientes chamam ele. Leia a `description` antes de escolher: ela ganha do nome do serviço e ganha da sua intuição.
Como decidir:
  1. Um serviço de cor só serve ao caso dela: use, fale o preço dele e siga para o horário.
  2. Dois ou mais servem, e a FOTO resolve (fundo mantido contra raiz clara): decida pela foto e diga qual você entendeu, numa frase curta, para ela corrigir se for o caso. "Pelo que vi, é morena iluminada, que mantém o fundo escuro."
  3. Dois ou mais servem e a foto NÃO resolve, ou não tem foto: faça UMA pergunta que separa os dois, com as palavras dela. "Você quer manter o fundo escuro ou clarear tudo?" Uma pergunta, não um menu, e não a lista de preços dos dois.
NUNCA escolha no chute quando dois serviços cabem. Preço de um com agenda do outro é o erro que só aparece na cadeira, e aí já é tarde.
E não invente serviço: se o que ela descreve não existe no catálogo deste salão, isso é ASK_OWNER.$b$, 482, 'ACTIVE')

on conflict (code) do update
  set title = excluded.title, body = excluded.body,
      position = excluded.position, status = excluded.status;
