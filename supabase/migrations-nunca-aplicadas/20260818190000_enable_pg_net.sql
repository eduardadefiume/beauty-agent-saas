-- Habilita pg_net.
--
-- Uso imediato: sondar o proprio endpoint de webhook do WhatsApp a partir do
-- banco, para distinguir "funcao sem segredos configurados" (503) de "funcao
-- configurada rejeitando token errado" (403). O ambiente de desenvolvimento
-- remoto nao alcanca a internet, entao esta e a unica forma de fazer a sonda.
--
-- Resultado da sonda em 18/08/2026: 403 Forbidden. Confirma que a funcao esta
-- publicada, que WHATSAPP_VERIFY_TOKEN e META_APP_SECRET estao configurados, e
-- que o handshake rejeita token invalido como deveria.
--
-- Uso permanente: pg_net e pre-requisito da decisao D5 do plano estrategico --
-- pg_cron + pg_net invocando Edge Functions para projecao de inbox, expiracao
-- de sinal e outbox de campanha.

create extension if not exists pg_net with schema extensions;
