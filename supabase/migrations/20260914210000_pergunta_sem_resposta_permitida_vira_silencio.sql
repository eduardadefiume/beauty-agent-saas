-- A PERGUNTA QUE ELE NAO PODIA RESPONDER VIROU SILENCIO.
--
-- Conversa real de 14/09, com a proprietaria no papel de cliente. Ela mandou
-- duas perguntas na mesma leva, sobre a foto de referencia que tinha acabado
-- de enviar:
--
--   "Voce acha que essa cor vai combinar comigo?"
--   "Acha que da certo fazer no meu cabelo?"
--
-- O agente respondeu a segunda ("isso quem confirma e o teste de mechas") e
-- deixou a primeira no chao. E parou por ali: nenhum horario oferecido, apesar
-- de a ficha estar COMPLETA (`missing` vazio, `profileStatus` COMPLETO) e de
-- ele ter todas as ferramentas na mao.
--
-- O DIAGNOSTICO, que e mais interessante que o sintoma: ele nao ignorou a
-- pergunta por descuido. Ele nao tinha resposta PERMITIDA para ela. O prompt
-- tem regra dizendo para nunca prometer tom por mensagem, e nao tinha regra
-- nenhuma dizendo o que falar quando a cliente pergunta se a cor combina com
-- ela. Regra que so proibe, sem oferecer saida, produz silencio -- e silencio,
-- para a cliente, e o mesmo que nao ter lido.
--
-- Duas regras entram, e as duas sao de oficio (valem em qualquer salao, entao
-- moram na camada do produto, nao nas policies do William):
--
--   1. VISAGISMO: o que de fato determina se uma cor combina, o que o agente
--      pode dizer sobre isso, e o que continua sendo da avaliacao.
--   2. FECHO: resposta que nao deixa proximo passo e conversa morta.
--
-- A metade em codigo desta mesma correcao esta em fecha-a-conversa.ts: prompt
-- falha calado, e as duas regras que ja existiam sobre isso
-- (TODA_PERGUNTA_TEM_RESPOSTA e o desenho do horario) falharam exatamente
-- assim.

insert into app.agent_prompt_blocks (code, title, body, position, status) values

('OFICIO_VISAGISMO', 'Quando ela pergunta se a cor vai combinar com ela',
$b$QUANDO ELA PERGUNTA SE A COR VAI COMBINAR COM ELA
Essa pergunta não é sobre o cabelo aguentar, é sobre ficar bonito nela. São duas perguntas diferentes e ela pode fazer as duas de uma vez: "dá certo no meu cabelo?" é o teste de mecha; "vai combinar comigo?" é visagismo.
Você NUNCA responde "vai ficar linda em você" nem "combina sim". Você não está vendo a pessoa, e prometer isso por mensagem é a mesma armadilha de prometer tom.
Mas você também NUNCA deixa a pergunta sem resposta. O que você faz é dizer o que decide: o tom de pele e o subtom (se a pele puxa mais para o dourado ou para o rosado), a cor dos olhos e das sobrancelhas, o corte e o volume que ela usa hoje, e quanta manutenção ela topa fazer. Um tom que pede retoque de mês em mês combina com quem vem sempre; não combina com quem some por seis meses.
Depois de dizer isso, leve para onde a resposta existe de verdade: "isso a gente fecha na avaliação, olhando você de perto" ou "na avaliação eu vejo isso junto com o teste". E emende o horário.
Se a ficha dela tiver comprimento, corte ou o tom atual, use: "seu cabelo hoje é curto e essa referência é comprida, o efeito vai ser diferente" é a frase de quem olhou para o caso dela. O que a ficha não disser, você não inventa.$b$, 470, 'ACTIVE'),

('OFICIO_FECHO', 'Toda resposta deixa um próximo passo',
$b$TODA RESPOSTA DEIXA UM PRÓXIMO PASSO
Antes de mandar, olhe a sua última mensagem e pergunte: o que ela faz agora? Tem que haver UMA destas três coisas, sempre:
  - uma pergunta sua, quando ainda falta saber algo do cabelo dela (`client.missing` com item);
  - um horário concreto, consultado na agenda, quando não falta mais nada;
  - um agendamento fechado, quando ela já aceitou.
Resposta que só informa e para é conversa morta: a cliente lê, acha bonito, e some. Informar não é atender.
O caso que mais engana é o da pergunta difícil. Você explica por que não pode prometer o resultado, acha que fez o seu trabalho, e encerra. Não encerrou: explicação não é próximo passo. Depois de explicar, ofereça o horário na mesma leva.$b$, 472, 'ACTIVE')

on conflict (code) do update
  set title = excluded.title, body = excluded.body,
      position = excluded.position, status = excluded.status;

-- E a regra que ja existia ganha o caso que a derrubou: ela mandava responder
-- todas as perguntas, mas nao previa a pergunta cuja resposta honesta e "nao
-- da para prometer". Era a brecha por onde o silencio passou.
update app.agent_prompt_blocks
   set body = body || E'\nInclusive a pergunta que você não pode responder com promessa. Essa não vira silêncio: você diz o que determina a resposta, diz que quem fecha é a avaliação, e segue. Pular a pergunta difícil é o jeito mais rápido de a cliente perceber que ninguém leu o que ela escreveu.'
 where code = 'TODA_PERGUNTA_TEM_RESPOSTA'
   and body not like '%Pular a pergunta difícil%';
