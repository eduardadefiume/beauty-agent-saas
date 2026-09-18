-- Agendador dos workers: o que faz o agente rodar sozinho.
--
-- Até aqui o agente e o remetente só rodavam quando alguém os chamava à mão.
-- Este arquivo é o relógio que os aciona. Três decisões moldam tudo o que vem
-- abaixo, e nenhuma delas é detalhe de implementação:
--
-- 1. A PARADA DE EMERGÊNCIA PARA O AGENTE, NUNCA O ENVIO. Com a chave
--    desligada, o tique do agente nem sai do banco — não gasta chamada nem
--    token. Mas o remetente continua rodando sempre, porque a fila de saída
--    também carrega mensagem escrita por gente da equipe, e nenhuma decisão
--    sobre o agente pode prender a mensagem de uma pessoa.
--
-- 2. DOIS TIQUES NÃO PODEM PEGAR A MESMA CONVERSA. Se um tique demora mais que
--    o intervalo, o seguinte encontraria a mesma conversa ainda na fila e
--    responderia de novo — a cliente receberia duas respostas. Por isso todo
--    disparo fica registrado e um novo só sai se o anterior já tiver
--    encerrado (ou passado de cinco minutos, para que um travamento não
--    congele o agendador para sempre).
--
-- 3. FALHA CALADA É PIOR QUE FALHA. O pg_net é assíncrono: net.http_post
--    devolve um número na hora e a resposta chega depois. Sem reconciliar, um
--    worker quebrado devolveria 500 a cada minuto e ninguém veria. Cada tique
--    começa fechando os disparos anteriores, então o erro fica gravado e
--    visível.

create extension if not exists pg_cron;

-- Endereço das functions. Não é segredo (a URL é pública), mas é específico de
-- cada projeto — por isso mora em tabela e não no código. O JWT do portão e o
-- token de worker continuam no Vault.
create table if not exists app.worker_endpoints (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

comment on table app.worker_endpoints is
  'Configuração por projeto do agendador (ex.: functions_base_url). Semeada fora do controle de versão.';

-- Registro de cada disparo REAL. Tique em repouso não escreve aqui — senão a
-- tabela cresceria um registro por minuto dizendo "nada a fazer".
create table if not exists app.worker_runs (
  id            bigint generated always as identity primary key,
  worker        text not null check (worker in ('AGENTE', 'ENVIO')),
  request_id    bigint not null,
  dispatched_at timestamptz not null default now(),
  settled_at    timestamptz,
  status_code   int,
  outcome       jsonb
);

create index if not exists worker_runs_em_voo_idx
  on app.worker_runs (worker, dispatched_at desc)
  where settled_at is null;

create index if not exists worker_runs_recentes_idx
  on app.worker_runs (worker, dispatched_at desc);

comment on table app.worker_runs is
  'Um registro por disparo de worker, com o resultado reconciliado depois que o pg_net responde.';

-- Sinal de vida. Uma linha por worker, reescrita a cada tique — é assim que a
-- tela responde "o agendador está vivo" sem uma tabela que cresce sozinha.
create table if not exists app.worker_heartbeat (
  worker       text primary key check (worker in ('AGENTE', 'ENVIO')),
  last_tick_at timestamptz not null default now(),
  last_action  text not null
);

comment on table app.worker_heartbeat is
  'Último tique de cada worker e o que ele decidiu fazer. Mostra repouso proposital diferente de agendador morto.';

-- O conteúdo devolvido nem sempre é JSON (um erro do portão vem em texto).
-- Converter sem rede de proteção derrubaria a reconciliação inteira por causa
-- de uma resposta malformada.
create or replace function app.json_ou_texto(p_conteudo text)
returns jsonb
language plpgsql
immutable
as $$
begin
  if p_conteudo is null or p_conteudo = '' then
    return null;
  end if;
  return p_conteudo::jsonb;
exception
  when others then
    return jsonb_build_object('naoEraJson', left(p_conteudo, 500));
end;
$$;

-- Fecha os disparos cuja resposta já chegou. Roda no começo de todo tique,
-- porque o pg_net apaga as respostas dele depois de algumas horas — reconciliar
-- tarde é o mesmo que não reconciliar.
create or replace function app.settle_worker_runs()
returns void
language sql
security definer
set search_path = app, net, pg_catalog, public
as $$
  update app.worker_runs r
     set settled_at  = now(),
         status_code = resp.status_code,
         outcome     = coalesce(
                         app.json_ou_texto(resp.content),
                         jsonb_build_object('erro', coalesce(resp.error_msg, 'sem resposta'))
                       )
    from net._http_response resp
   where resp.id = r.request_id
     and r.settled_at is null;
$$;

-- O interruptor de emergência é POR SALÃO (app.agent_automation.tenant_id), não
-- global, e o agendador é um só para o projeto inteiro. A pergunta certa,
-- portanto, não é "a automação está ligada" e sim "existe ALGUM salão com ela
-- ligada". Errar nos dois sentidos custa caro: exigir todos ligados deixaria um
-- salão sem atendimento; ignorar o interruptor faria o botão vermelho mentir.
-- Quem filtra salão por salão continua sendo a fila — esta função só evita
-- gastar chamada quando ninguém está ligado.
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

-- Dispara um worker, com todas as travas no caminho.
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

  -- A parada de emergência só tranca o agente. O envio nunca para: a fila de
  -- saída também tem mensagem escrita por gente.
  if p_worker = 'AGENTE' and not app.any_agent_automation_enabled() then
    v_acao := 'REPOUSO_NENHUM_SALAO_LIGADO';
  elsif exists (
    select 1 from app.worker_runs
     where worker = p_worker
       and settled_at is null
       and dispatched_at > now() - interval '5 minutes'
  ) then
    -- O anterior ainda não voltou. Disparar agora faria dois tiques pegarem a
    -- mesma conversa e a cliente receberia a resposta duplicada.
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
                     'Content-Type',    'application/json',
                     'Authorization',   'Bearer ' || v_jwt,
                     'x-worker-token',  v_token
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

  -- Sete dias de histórico bastam para investigar uma falha; guardar mais só
  -- engorda a tabela.
  delete from app.worker_runs where dispatched_at < now() - interval '7 days';

  return v_acao;
end;
$$;

revoke all on function app.tick_worker(text, text, jsonb, int) from public, anon, authenticated;
revoke all on function app.settle_worker_runs() from public, anon, authenticated;

-- Um minuto é o compasso do agente (o pg_cron só aceita intervalo em segundos
-- de 1 a 59, então minuto tem que vir em formato cron clássico): ele já espera 25 segundos de silêncio antes
-- de responder, para não cortar a cliente no meio de uma sequência de
-- mensagens. Tique em repouso não custa token nenhum.
select cron.schedule('agente-whatsapp', '* * * * *', $cron$
  select app.tick_worker('AGENTE', 'whatsapp-agent', '{"limit": 5, "quietSeconds": 25}'::jsonb, 150000);
$cron$);

-- O envio corre mais solto: é o que faz a resposta sair rápido, e não gasta LLM.
select cron.schedule('envio-whatsapp', '30 seconds', $cron$
  select app.tick_worker('ENVIO', 'whatsapp-sender', '{}'::jsonb, 60000);
$cron$);
