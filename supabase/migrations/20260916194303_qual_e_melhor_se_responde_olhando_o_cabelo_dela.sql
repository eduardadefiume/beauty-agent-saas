-- "QUAL É MELHOR?" NÃO SE RESPONDE COM CARDÁPIO.
--
-- 16/09, 16:23, no número de verdade:
--   cliente: "Quero fazer luzes qual delas é melhor?"
--   cliente: "E qual eu faço primeiro?"
--   agente:  listou mechas e morena iluminada, listou as cinco progressivas,
--            e devolveu "qual desse efeito te agrada mais?".
--
-- Ela veio perguntar porque NÃO SABE. Devolver a lista é empurrar a escolha
-- para quem não tem como escolher. Na ficha dela, naquele instante, faltavam
-- as cinco coisas que decidem a resposta: foto do cabelo hoje, tom que ela
-- quer, se é colorido, se já tem química e a textura.
--
-- Parte da culpa é do recado da própria trava de IRMÃOS, escrito hoje de
-- manhã: ele manda "diga as opções com o que diferencia uma da outra". Isso
-- vale quando o que separa os irmãos é preferência dela. Quando o que separa
-- depende do cabelo, listar é o erro. O recado foi corrigido junto, no
-- index.ts, e a trava AVALIAR passa na frente de IRMAOS.
--
-- E a política 9 estava ERRADA sobre o Violet: dizia "o tratamento específico
-- para loira". Violet é indicado para loira, mas não é exclusivo dela: é
-- alisamento com componentes de hidratação, e quem manda é a TEXTURA do fio,
-- não a cor. Cabelo liso ou ondulado, cabe; crespo ou grosso, indica-se as
-- outras. Corrigido abaixo com o que a proprietária ditou.

update app.agent_policies p
set body = $corpo$Quando ela quiser luzes (ou mechas, ou iluminado) E progressiva, a ordem é esta, e não é preferência dela nem sua:
  LUZES PRIMEIRO. PROGRESSIVA DEPOIS, uma semana depois, no mínimo.
E a progressiva indicada nesse caso é a COM FORMOL: é a química mais compatível com cabelo que acabou de receber luzes.
O atendimento nesse caso segue nesta sequência:
  1. peça a foto do cabelo dela hoje, como ele está. Esta é a PRIMEIRA coisa, antes de valor e antes de lista de opções: sem ver o fio você não tem como indicar química nenhuma;
  2. peça a foto de referência, o tom que ela quer;
  3. diga a ordem e o porquê, curto: luzes primeiro, progressiva uma semana depois;
  4. diga os valores dos dois procedimentos;
  5. pergunte se ela vai querer fazer os dois.
Se ela disser que sim: agende as luzes, e a progressiva para uma semana depois, as duas na mesma conversa, não deixe a segunda "para combinar depois".
Se ela disser que quer só um: agende o que ela escolheu, sem insistir no outro.

SOBRE O VIOLET, e preste atenção porque é fácil errar isto:
O Violet é indicado para loira, mas NÃO é só para loira. Quem quiser formol pode fazer o Violet.
O que ele é: alisamento com componentes de hidratação junto.
Quem manda na indicação é a TEXTURA do fio, não a cor. Cabelo de aspecto mais liso, ou com ondas: o Violet cabe bem. Cabelo mais crespo ou mais grosso: você indica as outras progressivas, não o Violet.
E é por isso que a foto do cabelo dela vem antes de tudo. A cor você até adivinha pela conversa; a textura, não.$corpo$,
    title = 'Luzes e progressiva: a foto primeiro, depois a ordem, e a verdade sobre o Violet',
    updated_at = now()
from app.tenants t
where t.id = p.tenant_id and t.slug = 'piloto-eduarda' and p.position = 9;

insert into app.agent_policies (tenant_id, topic, title, body, status, position)
select t.id, 'PROCEDIMENTO', 'Quando ela pergunta qual é melhor, a resposta é uma foto',
$corpo$"Qual é melhor?", "qual você indica?", "qual eu faço primeiro?" - isso não é pergunta de catálogo, é pedido de indicação. E quem indica química precisa ver o cabelo.

Então, quando ela pedir indicação e você ainda não tiver a foto do cabelo dela e o tom que ela quer, a resposta deste turno é PEDIR essas duas coisas, uma por vez, começando pela foto do cabelo hoje.

Diga em uma linha por que está pedindo, com naturalidade: "pra te indicar a certa eu preciso ver como ele está hoje". Não é burocracia de cadastro, é o motivo real.

O que NÃO fazer nesse momento:
  não liste os serviços da família e pergunte qual agrada mais. Ela veio perguntar porque não sabe; a lista devolve o problema para ela;
  não dê valor antes da foto, porque o valor de luzes depende do cabelo;
  não escolha por ela também. Nem lista, nem palpite: foto.

Depois que a foto chegar, aí sim você indica, com o nome do serviço e o porquê em uma linha, e o valor junto.

E se ela mandou duas perguntas de uma vez, responda as duas - mas na ordem que resolve. Se uma delas só tem resposta depois da foto, diga isso e peça a foto; não invente meia resposta para não deixar pergunta sem retorno.$corpo$,
       'ACTIVE', 12
from app.tenants t where t.slug = 'piloto-eduarda'
on conflict do nothing;
