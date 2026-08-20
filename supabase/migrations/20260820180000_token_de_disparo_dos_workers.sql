-- Fecha um buraco encontrado ao testar o B4.
--
-- O PROBLEMA. `verify_jwt = true` numa Edge Function do Supabase quer dizer
-- "o cabecalho Authorization traz um JWT assinado por este projeto". A chave
-- anon E um JWT assinado por este projeto -- e ela e publica por natureza: vai
-- embutida no JavaScript que o navegador baixa. Ou seja, qualquer pessoa que
-- abra o site consegue o cracha que a `whatsapp-agent` e a `whatsapp-sender`
-- aceitam hoje.
--
-- O ESTRAGO POSSIVEL nao e vazamento de dado -- as duas nao recebem parametro
-- que escolha conversa. E custo e reputacao: a `whatsapp-agent` gasta token de
-- LLM a cada chamada, e a `whatsapp-sender` faz sair mensagem pelo numero do
-- salao. Um laco de chamadas nao autorizadas queima orcamento e fala com
-- cliente em nome do William.
--
-- A CORRECAO. Um segundo fator que nao e publico: um token aleatorio guardado
-- no Vault. Quem dispara os workers manda o token no cabecalho
-- `x-worker-token`; a funcao pergunta ao banco se confere.
--
-- POR QUE NO VAULT, E NAO NUMA VARIAVEL DE AMBIENTE. Porque quem vai disparar
-- e o proprio banco (pg_cron + pg_net, quando o agendador entrar). Guardado
-- aqui, quem chama e quem verifica leem da mesma fonte, e o token nunca precisa
-- passar pela mao de ninguem -- nem aparecer em log de conversa.

do $$
declare
  v_token text;
begin
  if exists (select 1 from vault.secrets where name = 'worker_trigger_token') then
    return;
  end if;

  -- 64 caracteres hexadecimais, ~244 bits de entropia. gen_random_uuid() e do
  -- nucleo do Postgres; evita depender de pgcrypto so para isto.
  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  perform vault.create_secret(
    v_token,
    'worker_trigger_token',
    'Token de disparo dos workers de WhatsApp (whatsapp-agent, whatsapp-sender).'
  );
end;
$$;

-- Verificacao do token.
--
-- Devolve booleano e nada mais: quem chamou errado nao descobre nada sobre o
-- token certo pela resposta. A comparacao nao e de tempo constante, o que e
-- aceitavel aqui -- adivinhar 244 bits por diferenca de milissegundos sobre
-- HTTP nao e um ataque praticavel.
create or replace function app.verify_worker_token(p_token text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
      from vault.decrypted_secrets s
     where s.name = 'worker_trigger_token'
       and p_token is not null
       and s.decrypted_secret = p_token
  );
$function$;

revoke all on function app.verify_worker_token(text) from public, anon, authenticated;
grant execute on function app.verify_worker_token(text) to service_role;

create or replace function public.verify_worker_token(p_token text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select app.verify_worker_token(p_token);
$function$;

revoke all on function public.verify_worker_token(text) from public, anon, authenticated;
grant execute on function public.verify_worker_token(text) to service_role;

comment on function app.verify_worker_token(text) is
  'Segundo fator de autorizacao dos workers de WhatsApp. verify_jwt sozinho aceita a chave anon, que e publica; este token nao e.';
