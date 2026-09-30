-- CORTE NÃO É QUÍMICA (no prompt que a atendente lê de verdade).
--
-- A migração 20260930183526 corrigiu app.product_rules, mas a atendente lê
-- app.agent_prompt_blocks (OFICIO_DUAS_QUIMICAS). Reteste 30/09 18:37: o combo
-- "corte e progressiva" continuou recusado como "muita química pra um dia só".
update app.agent_prompt_blocks
   set body = replace(
         body,
         E'Vale para luzes com progressiva, coloração com alisamento, e qualquer combinação de duas químicas pesadas.\n',
         E'Vale para luzes com progressiva, coloração com alisamento, e qualquer combinação de duas químicas pesadas.\n'
         || E'Corte, escova, hidratação, cronograma e finalização NÃO são química. Corte com progressiva, com coloração ou com luzes no mesmo dia é normal: você não recusa, não desaconselha e não fala em "muita química".\n'),
       updated_at = statement_timestamp()
 where code = 'OFICIO_DUAS_QUIMICAS'
   and body not like '%NÃO são química%';