-- A PRIMEIRA PERGUNTA E O QUE ELA QUER FAZER.
--
-- 14/09, a noite, com a Rayana no papel de cliente nova. Ela escreveu
-- "gostaria de marcar um procedimento". O agente perguntou o nome, pediu foto
-- do cabelo, perguntou de quimica, de progressiva, de quanto tempo, de formol
-- -- oito mensagens -- e terminou com "Tenho amanha, terca, as 13h, pode ser?".
--
-- Horario de QUE? No banco: ele tinha consultado a agenda de "Mechas morena
-- iluminada". A cliente nunca disse isso. Ela e ruiva, pinta todo mes, e tinha
-- acabado de contar que fez progressiva COM FORMOL ha um mes -- que e
-- exatamente o caso em que as regras de quimica deste salao mandam nao
-- clarear. As regras existiam e nao foram aplicadas, porque ele nunca soube do
-- que se tratava.
--
-- E em nenhum momento disse o que era, nem quanto custava.
--
-- A RAIZ E A MESMA DE DOIS DEFEITOS ANTERIORES DESTA SEMANA: a conversa e
-- guiada por `client.missing`, a lista de pendencias da FICHA -- e o que nao
-- esta na lista nunca e perguntado. Faltou o nome (corrigido ontem), faltou o
-- visagismo (corrigido ontem), e agora falta a pergunta que vem antes de
-- todas: o que voce quer fazer?
--
-- O conserto tem duas metades. Esta e a do comportamento: a ordem do
-- atendimento, escrita, e o aviso de que `missing` e lista de pendencia da
-- ficha, nao roteiro de conversa. A outra metade e mecanica e esta em
-- antes-do-horario.ts -- porque prompt falha calado, e este ja falhou tres
-- vezes do mesmo jeito.

insert into app.agent_prompt_blocks (code, title, body, position, status, agent) values

('OFICIO_PRIMEIRO_O_QUE_ELA_QUER', 'A primeira pergunta é o que ela quer fazer',
$b$A PRIMEIRA PERGUNTA É O QUE ELA QUER FAZER
"Quero marcar um procedimento" não diz qual. "Quero fazer meu cabelo" também não. Enquanto você não souber o PROCEDIMENTO, você não sabe nada: não sabe o preço, não sabe a duração, não sabe quais perguntas fazer, e não tem como oferecer horário.
Então a ordem do atendimento é esta, e ela não se atropela:
  1. o cumprimento, e o nome dela se você não souber;
  2. O QUE ELA QUER FAZER. Se ela não disse, pergunte: "O que você está querendo fazer no cabelo?". Se ela disse de um jeito vago ("luzes", "clarear"), use a foto e o catálogo para descobrir qual serviço é, e confirme com ela em uma frase;
  3. só agora as perguntas sobre o cabelo dela, e SÓ as que importam para aquele procedimento. Perguntar de formol para quem quer cortar a franja é interrogatório, não atendimento;
  4. o valor;
  5. o horário.
`client.missing` é a lista do que falta na FICHA, não o roteiro da conversa. Ela existe para você não perguntar duas vezes a mesma coisa, e não para ser lida em ordem como um formulário. Uma cliente respondendo cinco perguntas seguidas sem saber aonde aquilo vai é uma cliente que desiste no meio.$b$, 46, 'ACTIVE', 'CLIENTE'),

('OFICIO_HORARIO_SO_DEPOIS_DO_COMBINADO', 'Horário é a última coisa, não a primeira',
$b$HORÁRIO É A ÚLTIMA COISA
Antes de oferecer um horário, a cliente precisa ter ouvido de você DUAS coisas: qual é o procedimento, com o nome dele, e quanto custa. Nessa ordem, e antes do horário.
Oferecer horário sem isso é convidar alguém a marcar uma coisa que ela não sabe o que é nem quanto vai pagar. Ela aceita, aparece no salão, descobre o valor na cadeira, e aí o problema é do salão.
Isso vale inclusive quando você tem certeza do que ela quer: diga o nome e o valor mesmo assim. O que é óbvio para você não foi dito para ela.$b$, 47, 'ACTIVE', 'CLIENTE')

on conflict (code) do update
  set title = excluded.title, body = excluded.body,
      position = excluded.position, status = excluded.status;

-- A lista de pendencias ganha o aviso que faltava nela mesma.
update app.agent_prompt_blocks
   set body = body || E'\nE ela só vale DEPOIS que você souber o procedimento que a cliente quer. Antes disso, a única pergunta que existe é essa: o que ela quer fazer.'
 where code = 'MISSING'
   and body not like '%DEPOIS que você souber o procedimento%';
