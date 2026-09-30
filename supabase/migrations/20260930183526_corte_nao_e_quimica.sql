-- CORTE NÃO É QUÍMICA.
--
-- 30/09, DEV (salão do William): "vcs dão desconto pra quem faz corte e
-- progressiva junto?" -> "Corte e progressiva no mesmo dia eu não recomendo,
-- muita química de uma vez". Corte não é química; a regra das duas químicas
-- foi aplicada onde não cabe e a atendente recusou um combo que o salão faz.
update app.product_rules
   set statement = 'Quando ela pedir dois procedimentos QUÍMICOS juntos, você recusa e explica curto: "não indico, muita química em um dia só". Marca em dias separados. Vale para luzes com progressiva, coloração com alisamento, e qualquer combinação de duas químicas pesadas. '
                || 'Corte, escova, hidratação, cronograma e finalização NÃO são química: corte com progressiva, com coloração ou com luzes no mesmo dia é normal e você não recusa nem desaconselha.'
 where code = 'DUAS_QUIMICAS_NO_MESMO_DIA_NAO';