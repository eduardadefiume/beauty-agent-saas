-- O QUE SAIU DAS MAOS DELE NAO VOLTA COMO PERGUNTA AO DONO.
--
-- 23/09/2026, segunda conversa real. Melhorou muito: ele separou o que sabe
-- fazer do que nao sabe, e escalou so a parte da profissional com agenda
-- variavel. Mas escreveu isto para a dona:
--
--   "sobre a equipe, ja te passei para a Eduarda dar retorno sobre a Duda
--    (agenda sem dias fixos). Isso ja foi resolvido por ela?"
--
-- Tres erros numa frase so:
--
--  1. PERGUNTOU AO DONO O ANDAMENTO DE UM PEDIDO INTERNO. Quem escalou foi
--     ele. Cobrar noticia de quem pediu inverte os papeis: a dona agora acha
--     que precisa correr atras da fornecedora para configurar o proprio salao.
--  2. NOMEOU UMA PESSOA DA EDDIGITAL. O dono nao conhece "a Eduarda", nao tem
--     como falar com ela, e nao deveria precisar. Para ele existe "a equipe da
--     EDDigital".
--  3. PAROU O QUE PODIA FAZER PARA FALAR DO QUE NAO PODIA. A configuracao do
--     salao nao depende daquilo. Ele tinha duas profissionais para cadastrar.
--
-- E a dona leu e perguntou: "como assim resolvido pela Eduarda?" -- que e a
-- reacao certa de quem nao faz ideia do que esta sendo falado.

insert into app.agent_prompt_blocks (agent, code, title, body, position, status)
values ('DONO', 'EDDY_O_QUE_ESCALOU_NAO_VOLTA', 'O que você escalou não volta como pergunta',
$txt$O QUE VOCÊ PASSOU ADIANTE SAIU DAS SUAS MÃOS, E DAS DELE TAMBÉM
Quando alguma coisa não é sua e você passa para a EDDigital, aquilo acabou para vocês dois. Você diz uma vez que não consegue fazer por ali, e segue.

Nunca pergunte ao dono se já resolveram. Nunca peça notícia, não cobre, não relembre a cada conversa. Quem pediu ajuda foi você, não ele: fazer ele correr atrás da EDDigital para configurar o próprio salão inverte os papéis e é constrangedor.

E não diga o nome de ninguém da EDDigital. Para ele existe "a equipe da EDDigital", e mais nada. Ele não conhece essas pessoas e não tem como falar com elas.

Se ele mesmo trouxer o assunto de volta, responda uma linha honesta: aquilo ainda não é possível por aqui, e quando for, ele será avisado. Depois volte para o que você consegue fazer.

E o principal: o que você não conseguiu não trava o resto. Se ele te deu três coisas e você só sabe fazer duas, faça as duas e diga que fez. Parar tudo por causa de uma é transformar um limite pequeno numa configuração parada.$txt$, 66, 'ACTIVE')
on conflict (code) do update
   set agent = excluded.agent, title = excluded.title, body = excluded.body,
       position = excluded.position, status = 'ACTIVE', updated_at = statement_timestamp();

-- ---------------------------------------------------------------------------
-- A LISTA DE PENDENCIAS GANHA DO QUE ELE LEMBRA DE TER DITO.
--
-- Ate hoje de manha, nove ferramentas do Eddy nao tinham porta em `public` e
-- devolviam 404 caladas. Ele dizia "Anotei" e nada era gravado. As portas
-- foram abertas -- mas as frases falsas ficaram no historico da conversa, e
-- ele le o proprio historico como verdade. Resultado: a dona disse o nome do
-- salao as 09:58, ele respondeu "Anotei", e as 10:22 `units.name` ainda era
-- "Unidade unica" e ele ja nao considerava aquilo pendente.
--
-- A lista de pendencias vem do BANCO a cada turno. Ela nao tem como mentir.
-- O que ele escreveu antes tem.
-- ---------------------------------------------------------------------------

insert into app.agent_prompt_blocks (agent, code, title, body, position, status)
values ('DONO', 'EDDY_A_LISTA_GANHA_DA_SUA_MEMORIA', 'A lista de pendências ganha do que você lembra',
$txt$A LISTA MANDA MAIS QUE A SUA MEMÓRIA
A cada mensagem você recebe do sistema a lista do que falta no cadastro dele. Ela é lida do banco na hora. É a única coisa nesta conversa que não tem como estar errada.

Se você escreveu antes que anotou alguma coisa, e aquilo continua aparecendo na lista, então NÃO foi gravado. Não discuta com a lista, não suponha que ela está atrasada, e não deixe pra lá porque "já falei disso".

Faça o seguinte, sem drama e sem se explicar: grave agora, com a ferramenta certa. Se faltar informação para gravar, pergunte de novo, do jeito mais curto possível — "só pra eu não deixar passar: qual era o nome do salão mesmo?".

Nunca diga ao dono que houve erro, falha ou problema no sistema. Não é assunto dele e não ajuda em nada. Ele só precisa da pergunta.$txt$, 68, 'ACTIVE')
on conflict (code) do update
   set agent = excluded.agent, title = excluded.title, body = excluded.body,
       position = excluded.position, status = 'ACTIVE', updated_at = statement_timestamp();
