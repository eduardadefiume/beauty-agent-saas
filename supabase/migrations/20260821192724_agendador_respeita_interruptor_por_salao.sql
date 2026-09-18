-- O interruptor de emergência é por salão (app.agent_automation.tenant_id), não
-- global. O agendador é um só para o projeto inteiro, então a pergunta certa
-- não é "a automação está ligada" e sim "existe ALGUM salão com ela ligada".
-- Errar isso nos dois sentidos é ruim: um agendador que exige todos ligados
-- deixaria um salão sem atendimento, e um que ignora o interruptor faria o
-- botão vermelho mentir. Quem filtra salão por salão continua sendo a fila
-- (list_conversations_awaiting_agent) — esta função só evita gastar chamada
-- quando ninguém está ligado.
create or replace function app.any_agent_automation_enabled()
returns boolean
language sql
stable
security definer
set search_path = app, pg_catalog
as $$
  select exists (select 1 from app.agent_automation where enabled);
$$;

revoke all on function app.any_agent_automation_enabled() from public, anon, authenticated;

create or replace function app.tick_worker(p_worker text, p_funcao text, p_corpo jsonb, p_timeout_ms int)
returns text
language plpgsql
security definer
set search_path = app, net, vault, pg_catalog, public
as $$
declare
  v_base    text;
  v_jwt     text;
  v_token   text;
  v_req     bigint;
  v_acao    text;
begin
  perform app.settle_worker_runs();

  if p_worker = 'AGENTE' and not app.any_agent_automation_enabled() then
    v_acao := 'REPOUSO_NENHUM_SALAO_LIGADO';
  elsif exists (
    select 1 from app.worker_runs
     where worker = p_worker
       and settled_at is null
       and dispatched_at > now() - interval '5 minutes'
  ) then
    v_acao := 'PULADO_ANTERIOR_EM_VOO';
  else
    select value into v_base from app.worker_endpoints where key = 'functions_base_url';
    select decrypted_secret into v_jwt   from vault.decrypted_secrets where name = 'worker_gateway_jwt';
    select decrypted_secret into v_token from vault.decrypted_secrets where name = 'worker_trigger_token';

    if v_base is null or v_jwt is null or v_token is null then
      v_acao := 'SEM_CONFIGURACAO';
    else
      v_req := net.http_post(
        url     := v_base || '/functions/v1/' || p_funcao,
        headers := jsonb_build_object(
                     'Content-Type',   'application/json',
                     'Authorization',  'Bearer ' || v_jwt,
                     'x-worker-token', v_token
                   ),
        body    := p_corpo,
        timeout_milliseconds := p_timeout_ms
      );

      insert into app.worker_runs (worker, request_id) values (p_worker, v_req);
      v_acao := 'DISPARADO';
    end if;
  end if;

  insert into app.worker_heartbeat (worker, last_tick_at, last_action)
  values (p_worker, now(), v_acao)
  on conflict (worker) do update
    set last_tick_at = excluded.last_tick_at,
        last_action  = excluded.last_action;

  delete from app.worker_runs where dispatched_at < now() - interval '7 days';

  return v_acao;
end;
$$;

revoke all on function app.tick_worker(text, text, jsonb, int) from public, anon, authenticated;