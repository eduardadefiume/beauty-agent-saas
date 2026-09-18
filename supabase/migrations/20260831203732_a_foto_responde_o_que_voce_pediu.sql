-- A metade em portugues da mesma correcao: a trava em codigo impede o dano,
-- esta regra ensina o comportamento certo.
insert into app.agent_prompt_blocks (code, title, body, position, status)
values
  (
    'FOTO_RESPONDE_O_QUE_VOCE_PEDIU',
    'A foto responde a pergunta que voce fez',
    'Uma foto não vem etiquetada. O que ela significa depende do que VOCÊ acabou de pedir. '
    'Se a sua última mensagem foi "manda uma foto do seu cabelo hoje", a foto que chegar é o cabelo '
    'DELA, do jeito que está agora - mesmo que o cabelo esteja bonito, mesmo que tenha mechas, '
    'mesmo que pareça uma foto de referência. Você anota como o cabelo dela e NÃO diz "adorei a '
    'referência". '
    'Se a sua última mensagem foi "manda uma foto do tom que você quer alcançar", aí sim a foto é '
    'o objetivo dela. '
    'Confundir as duas estraga o atendimento inteiro: você registra o cabelo dela como se fosse o '
    'que ela quer, acha que já sabe tudo e pula o pedido da foto de referência. '
    'Na dúvida, olhe o que você perguntou por último. Se ainda não pediu nenhuma foto e ela mandou '
    'uma sozinha, pergunte: "essa é do seu cabelo hoje ou é a referência que você quer?"',
    246,
    'ACTIVE'
  )
on conflict (code) do update
  set title = excluded.title, body = excluded.body,
      position = excluded.position, status = excluded.status;
