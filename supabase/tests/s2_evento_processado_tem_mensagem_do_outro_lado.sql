-- S2: todo evento de mensagem marcado PROCESSED tem uma linha em crm_messages.
--
-- No dia 31/08, 38 eventos (30 textos, 8 fotos) de uma conversa real saíram da
-- projeção como PROCESSED e nenhuma mensagem apareceu do outro lado. Sem
-- failure_reason, sem log. O banco dizia que estava tudo certo.
--
-- Este teste tranca as duas metades da defesa que saiu disso:
--
--   1. A lista de "processado sem par" está vazia. É a pergunta cuja resposta
--      certa é sempre zero, e a função app.inbox_processados_sem_par() existe
--      para respondê-la.
--
--   2. A projeção NÃO CONSEGUE mais produzir esse estado. Um gatilho temporário
--      engole o insert de uma mensagem sintética; a projeção precisa perceber
--      que a linha não existe e marcar FAILED com motivo, não PROCESSED.
--
-- Roda só contra o projeto DEV e desfaz tudo no fim.

begin;

-- Metade 1: nada escapou.
do $$
declare
  v_quantos integer;
  v_amostra text;
begin
  select count(*), string_agg(external_event_id, ', ')
    into v_quantos, v_amostra
    from (select external_event_id from app.inbox_processados_sem_par() limit 5) x;

  if v_quantos > 0 then
    raise exception 'Eventos de mensagem PROCESSED sem linha em crm_messages (amostra): %', v_amostra;
  end if;
end $$;

-- Metade 2: a trava dispara.
create function pg_temp.s2_engole_a_mensagem() returns trigger
language plpgsql as $$
begin
  if new.provider_message_id = 'message:wamid.S2_TESTE_PERDA_SILENCIOSA' then
    return null;
  end if;
  return new;
end $$;

create trigger s2_engole before insert on app.crm_messages
  for each row execute function pg_temp.s2_engole_a_mensagem();

do $$
declare
  v_tenant uuid;
  v_conexao uuid;
  v_evento uuid;
  v_status text;
  v_motivo text;
  v_falhados integer;
begin
  select e.tenant_id, e.connection_id into v_tenant, v_conexao
    from app.inbox_events e where e.event_type like 'WHATSAPP\_MESSAGE\_%'
   order by e.received_at desc limit 1;

  if v_tenant is null then
    raise exception 'S2 precisa de ao menos um evento de mensagem real para copiar tenant e conexao';
  end if;

  -- received_at em 2000 para ser o primeiro da fila, na frente de qualquer
  -- evento real que esteja pendente neste instante.
  insert into app.inbox_events (
    tenant_id, connection_id, provider, external_event_id, event_type,
    payload, payload_sha256, contact_authorized, status, correlation_id, received_at
  ) values (
    v_tenant, v_conexao, 'WHATSAPP',
    'message:wamid.S2_TESTE_PERDA_SILENCIOSA', 'WHATSAPP_MESSAGE_TEXT',
    jsonb_build_object('message', jsonb_build_object(
      'id', 'wamid.S2_TESTE_PERDA_SILENCIOSA',
      'from', '5500000000000',
      'timestamp', '946684800',
      'type', 'text',
      'text', jsonb_build_object('body', 'S2: esta mensagem nao pode virar silencio'))),
    encode(sha256('S2'::bytea), 'hex'), true, 'PENDING', 'S2-TESTE',
    '2000-01-01 00:00:00+00'
  ) returning id into v_evento;

  select falhados into v_falhados from app.project_inbox_events(1);

  select status::text, failure_reason into v_status, v_motivo
    from app.inbox_events where id = v_evento;

  if v_status <> 'FAILED' then
    raise exception 'A trava nao disparou: o evento saiu como % (motivo: %)', v_status, coalesce(v_motivo, '-');
  end if;
  if v_motivo not like '%PROJECAO_SEM_MENSAGEM%' then
    raise exception 'Falhou pelo motivo errado: %', v_motivo;
  end if;
  if v_falhados <> 1 then
    raise exception 'A projecao contou % falhados, esperava 1', v_falhados;
  end if;
end $$;

select 'S2 OK: nenhum processado sem par, e a projecao marca FAILED quando a mensagem nao entra' as resultado;

rollback;
