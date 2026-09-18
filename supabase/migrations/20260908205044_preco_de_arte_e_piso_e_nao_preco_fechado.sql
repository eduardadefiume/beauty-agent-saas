-- A metade em portugues da trava de preco.
--
-- A trava em codigo (supabase/functions/whatsapp-agent/preco-com-lastro.ts)
-- impede o dano: numero sem lastro nos dados nao chega na cliente. Ela nao
-- ensina nada, so segura. Estas duas regras ensinam o comportamento certo, e
-- cobrem o buraco que a trava nao cobre por natureza.
--
-- O BURACO. A trava compara numeros. O piloto tem UMA arte no ar, e ela diz
-- "A PARTIR DE R$ 430,00" e, embaixo, "CABELOS LONGOS, VOLUMOSOS E COM
-- CORRECAO DE COR precisam ser avaliados". Se o agente escrever "fica R$ 430"
-- para uma cliente de cabelo longo, o 43000 esta na arte, a trava deixa
-- passar - e o salao acabou de prometer um preco que a propria arte dele
-- condiciona. Numero certo, promessa errada. Isso e comportamento, e
-- comportamento se escreve em portugues.
--
-- A segunda regra e o par da trava: o codigo bloqueia soma de precos, entao o
-- modelo precisa saber por que, senao ele tenta, cai em HANDOFF e a cliente
-- espera uma pessoa por um motivo que ninguem explicou a ele.
update app.agent_prompt_blocks
   set body =
        'ONDE O PREÇO PODE ESTAR' || chr(10) ||
        'O catálogo é a primeira fonte. Mas `priceMinor` null NÃO quer dizer que o preço não '
        'existe: quer dizer que não foi cadastrado ali. O valor pode estar numa arte de '
        '`statusArts` que o próprio salão publicou, ou numa regra de `policies`. Preço que o salão '
        'publicou é preço válido: use, do jeito que as `policies` mandarem falar dele.' || chr(10) ||
        'Só quando nenhuma das três fontes disser nada é que você não sabe o preço.' || chr(10) ||
        'PREÇO DE ARTE QUASE NUNCA É PREÇO FECHADO. "A partir de R$ X" é piso: diga que começa em '
        'X, nunca que custa X. E se a arte condiciona o valor a alguma coisa do cabelo dela '
        '(comprimento, volume, correção de cor), o preço não está fechado nem como piso: fale de '
        'onde começa e diga que o valor dela sai na avaliação.' || chr(10) ||
        'Você também não soma preços para dar um total, nem monta pacote. Dois serviços juntos '
        'podem custar menos que a soma, ou exigir mais tempo: quem fecha isso é a dona.'
 where code = 'PRECO';
