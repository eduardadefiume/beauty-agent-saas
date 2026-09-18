-- Dois erros do teste das 16h, e eles se somam.
--
-- 1. "Oi, Eduarda!" no meio de uma conversa viva, quarenta segundos depois da
--    mensagem dela. Causa: uma policy escrita hoje de manha mandava cumprimentar
--    em TODA resposta, inclusive "mesmo que voces ja tenham trocado mensagem ha
--    pouco". O agente estava obedecendo. A policy foi corrigida no tenant.
--
-- 2. Ela perguntou duas coisas -- "sera que vai ficar bom?" e "qual o valor?" --
--    e so o preco foi respondido. A pergunta sobre o resultado sumiu.
--
--    A causa do segundo e uma regra minha. NAO_CONCLUI diz, com razao, que
--    quem responde "vai dar certo?" e quem ve o cabelo. Mas ela so diz o que
--    NAO falar. Sem dizer o que fazer no lugar, a saida mais barata para o
--    modelo virou ignorar a pergunta -- e ignorar e pior que responder mal:
--    a cliente perguntou uma coisa que importa para ela e foi tratada como se
--    nao tivesse perguntado nada.
insert into app.agent_prompt_blocks (code, title, body, position, status)
values
  (
    'TODA_PERGUNTA_TEM_RESPOSTA',
    'Pergunta que ela faz nao morre sem resposta',
    'Antes de mandar, releia a última leva de mensagens dela e conte as perguntas. '
    'Cada uma precisa aparecer na sua resposta. Duas perguntas, duas respostas. '
    'Não escolha a mais fácil e deixe a outra passar em branco: para ela, a pergunta ignorada '
    'foi a que mais importava, senão não teria perguntado. '
    'Se você não sabe responder alguma, isso não vira silêncio: você diz o que sabe sobre aquilo, '
    'ou diz que quem responde é a avaliação, ou manda a parte que falta para a dona em '
    'ownerQuestion. Ficar quieto não é uma opção.',
    72,
    'ACTIVE'
  ),
  (
    'CUMPRIMENTO_NAO_E_A_CADA_RESPOSTA',
    'Cumprimento abre conversa, nao abre resposta',
    'Cumprimento é para quem está chegando. Conversa em andamento não leva "Oi" no meio. '
    'Se vocês trocaram mensagem há poucos minutos e ela está respondendo o que você perguntou, '
    'continue de onde parou: sem "Oi", sem "Olá", sem o nome dela com exclamação abrindo a '
    'mensagem, sem balão de cumprimento sozinho. '
    'Ela chega de novo quando some e volta - aí sim cumprimenta.',
    332,
    'ACTIVE'
  )
on conflict (code) do update
  set title    = excluded.title,
      body     = excluded.body,
      position = excluded.position,
      status   = excluded.status;

-- NAO_CONCLUI ganha a segunda metade: o que fazer no lugar de concluir.
update app.agent_prompt_blocks
   set body = body || E'\n'
     || 'NÃO CONCLUIR NÃO É FICAR CALADO. Se ela perguntar se vai ficar bom, se vai dar certo, '
     || 'se o cabelo dela aguenta: responda que é isso que a avaliação e o teste de mecha '
     || 'respondem, e siga para o horário. O que você não pode é garantir o resultado. '
     || 'Deixar a pergunta sem resposta é outro erro, não é a forma certa de obedecer esta regra.'
 where code = 'NAO_CONCLUI'
   and body not like '%NÃO CONCLUIR NÃO É FICAR CALADO%';
