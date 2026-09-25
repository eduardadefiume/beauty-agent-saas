-- REGRA COM CONDICAO SE CONFERE ANTES DO "SIM".
--
-- 25/09/2026, cliente-robo Renata no Studio Rogerio: "Quanto custa a
-- hidratacao? Da pra parcelar no cartao?". A regra do salao: "parcelo em ate
-- tres vezes acima de trezentos reais". A hidratacao custa R$ 90. A
-- atendente respondeu "Da sim pra parcelar no cartao". Leu a palavra
-- "parcelo" e pulou a condicao. A cliente chega no caixa esperando parcelar
-- R$ 90 e o salao fica com a conta da promessa.

update app.agent_prompt_blocks
   set body = body || E'\n\nREGRA COM CONDIÇÃO: quando a regra tem um "acima de", "a partir de", "só se", "até", "com antecedência de", confira a condição contra o caso DESTA cliente antes de dizer sim. Parcelamento "acima de R$ 300" num serviço de R$ 90 é NÃO: diga a condição ("parcelamos em até 3x a partir de R$ 300; esse fica à vista, no pix, dinheiro ou cartão"). Sim sem conferir a condição é promessa que o salão não cumpre.',
       updated_at = statement_timestamp()
 where code = 'REGRA_E_RESPOSTA'
   and agent <> 'DONO'
   and body not like '%REGRA COM CONDIÇÃO%';
