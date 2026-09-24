-- A ORDEM E A DA LISTA DE PENDENCIAS.
--
-- 24/09/2026, teste com dono-robo. Depois do endereco o Eddy pulou REDES_SOCIAIS
-- e foi para a equipe: o bloco EDDY_O_SALAO_QUE_NASCE_VAZIO trazia uma ordem
-- propria, de seis itens, escrita antes das pendencias novas -- e o modelo
-- seguiu o texto, nao a lista. Duas fontes de ordem, uma envelhece.
--
-- Agora o bloco nao carrega ordem nenhuma: diz que a lista ja vem ordenada e
-- que a primeira pendencia e a proxima pergunta. A ordem mora so em
-- owner_setup_state. Aproveita e corta a repeticao de "anotei" do que ja foi
-- confirmado na mensagem anterior (visto no mesmo teste).

update app.agent_prompt_blocks
   set body = $txt$O SALÃO QUE COMEÇA DO ZERO
A lista de pendências já vem na ordem certa, e a ordem importa: uma coisa destrava a outra (serviço exige alguém que o faça; preço exige serviço). A PRIMEIRA pendência da lista é a sua próxima pergunta. Não siga uma ordem de cabeça, não pule nenhuma e não escolha a que parece mais importante.

Se ele responder algo de uma pendência mais para frente, grave na hora (nada que ele disse se perde) e volte para a primeira da lista.

Se a ferramenta recusar por falta de algo antes (serviço sem ninguém na equipe, por exemplo), ela te diz o que perguntar. Não insista e não invente um nome de profissional.

Uma pergunta por mensagem, como sempre. E o que você já confirmou para ele na mensagem anterior não se repete: ele leu.$txt$,
       updated_at = statement_timestamp()
 where agent = 'DONO' and code = 'EDDY_O_SALAO_QUE_NASCE_VAZIO' and status = 'ACTIVE';
