-- 21/09 criou agent_record_usage com p_agente DEFAULT NULL e deixou a antiga
-- de 10 parametros no lugar. Quem chama com 10 argumentos casa com as duas, o
-- Postgres recusa ("is not unique") e o chamador engole o erro. Resultado: zero
-- linhas em app.agent_usage desde 20/09. A versao de 11 parametros ja deduz o
-- agente pela conversa, entao apagar a antiga nao muda nenhum chamador.
drop function if exists public.agent_record_usage(uuid, uuid, text, text, integer, integer, integer, integer, integer, text);