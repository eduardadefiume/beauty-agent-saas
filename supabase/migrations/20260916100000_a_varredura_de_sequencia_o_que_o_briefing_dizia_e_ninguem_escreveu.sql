-- A VARREDURA DE SEQUENCIA: O QUE O BRIEFING DIZIA E NINGUEM ESCREVEU.
--
-- A dona pediu a varredura que eu devia ter feito na primeira leitura:
-- procurar ORDEM, INTERVALO e COMBINACAO, e nao proibicao.
--
-- ANTES DE TUDO, O ACHADO QUE MUDA O TAMANHO DA VARREDURA: as tabelas do
-- arquivo estao VAZIAS. `wa_archives`, `wa_archive_messages` e
-- `wa_archive_findings` tem zero linhas. As 551 conversas nunca foram
-- importadas -- a etapa 6 do roadmap continua em andamento. A unica fonte que
-- existe no repositorio e `docs/briefing-voz-william.md`, 272 linhas que a
-- propria dona extraiu. E foi dela que eu li, e e so dela que da para varrer.
--
-- Isso importa porque muda o que eu posso prometer: o protocolo de luzes com
-- progressiva que ela me ditou ontem NAO esta no briefing. Ele estava na
-- cabeca dela. Nenhuma varredura teria achado.
--
-- O QUE A VARREDURA ACHOU no briefing, em forma de sequencia, e que ainda nao
-- estava escrito em lugar nenhum:
--
--   1. "Cliente que ja e da casa: olhar o historico e marcar como de costume.
--      Se ela quiser MUDAR o tom, ai entra o teste de mechas e a media."
--      -> a regra da cliente fixa existia; o RAMO da mudanca de tom, nao.
--
--   2. "Nao cancelar nem remarcar com menos de 24h sem cobrar. A politica
--      escrita existe para dar um susto; hoje o William reagenda sem cobrar."
--      -> o briefing declara uma CONTRADICAO entre a regra escrita e a
--      pratica. Isso o agente nao resolve sozinho, em nenhuma direcao.
--
-- O resto das sequencias do briefing ja estava no banco: a ordem da resposta
-- de preco, o protocolo de cor com teste de mecha, a cadencia de retorno por
-- procedimento, o lembrete de vespera com texto exato, o oferecer horario em
-- vez de perguntar preferencia.

-- 1. O ramo que faltava na cliente da casa.
update app.agent_prompt_blocks
   set body = body || E'\nMAS se ela quiser MUDAR alguma coisa -- outro tom, outra cor, um procedimento que ela nunca fez -- aí não é o de sempre, e o caminho é o da cliente nova naquele ponto: avaliação, teste de mecha e o valor médio. Ser da casa poupa a apresentação, não poupa o teste.'
 where code = 'OFICIO_CLIENTE_FIXA'
   and body not like '%não é o de sempre%';

-- 2. A contradicao do prazo de 24h, declarada como contradicao.
insert into app.agent_policies (tenant_id, topic, title, body, position)
select t.id, v.topic::app.policy_topic, v.title, v.body, v.position
  from app.tenants t
 cross join (values
  ('AGENDAMENTO', 'Remarcar em cima da hora: nem prometer, nem ameaçar',
   E'A regra escrita, que vai no lembrete da véspera, diz que com menos de 24h não dá para cancelar ou remarcar e que o valor continua devido.\n'
   'Na prática o William reagenda sem cobrar. A regra existe para dar um susto e segurar a agenda, não para ser aplicada ao pé da letra.\n'
   'Então quando ela avisar em cima da hora, você NÃO faz nenhuma das duas coisas: não perdoa a taxa por conta própria e não cobra dela. Você acolhe sem drama, oferece outro horário concreto, e manda a pergunta para a dona em ownerQuestion na mesma resposta — quem decide isenção é o salão, caso a caso.\n'
   'Nunca repita a frase da cobrança para a cliente como ameaça. Ela já recebeu essa regra no lembrete.',
   10)
 ) as v(topic, title, body, position)
 where t.slug = 'piloto-eduarda'
on conflict do nothing;
