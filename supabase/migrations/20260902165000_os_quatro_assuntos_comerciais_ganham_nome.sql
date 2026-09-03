-- Pagamento, cancelamento, atraso e sinal viram assunto de regra.
--
-- O bloco NUNCA_INVENTE do prompt já nomeia esses quatro como o lugar onde
-- inventar não é errinho de conversa: "é um compromisso que o salão vai ter
-- que honrar ou desmentir na frente da cliente". Mesmo assim eles não tinham
-- onde morar -- `app.policy_topic` ia de VOZ a OUTRO e parava.
--
-- Sem assunto próprio, a regra de pagamento cairia em OUTRO junto com todo o
-- resto, e a lista de pendências do onboarding não teria como perguntar "e o
-- pagamento?" sem perguntar de novo o que já foi respondido.
--
-- Vai em migração separada porque `alter type ... add value` não pode ser
-- usado na mesma transação que passa a comparar contra o valor novo.

alter type app.policy_topic add value if not exists 'PAGAMENTO';
alter type app.policy_topic add value if not exists 'CANCELAMENTO';
alter type app.policy_topic add value if not exists 'ATRASO';
alter type app.policy_topic add value if not exists 'SINAL';
