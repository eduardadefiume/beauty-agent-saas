-- A FACHADA DESCARTAVA A FOTO ANTES DE CHEGAR NA PORTA.
--
-- 23/09/2026, mesma noite da trava do `kind`. Na 194500 eu escrevi que
-- consertar a trava NAO faz foto funcionar, porque havia um segundo buraco no
-- mesmo caminho, e que a fachada ficava para uma tarefa propria com teste de
-- ponta a ponta. Esta e a tarefa, e o teste esta em
-- `apps/web/app/midia-no-outbox.test.ts`.
--
-- O DEFEITO, em uma linha: `public.enqueue_outbound_message` tem seis
-- argumentos e nenhum deles e de midia. A interna
-- `app.enqueue_outbound_message` tem nove desde 27/08 -- os tres ultimos sao
-- `p_media_storage_path`, `p_media_mime_type` e `p_media_filename` --, e a
-- fachada a chama passando seis. Os tres de midia ficam no default (null), e a
-- interna, que decide o `kind` por `v_tem_midia`, conclui TEXT.
--
-- POR QUE ISSO IMPORTA: o PostgREST deste projeto expoe `public` e mais nada.
-- Toda chamada vinda de Edge Function -- `eddy-agent`, `whatsapp-agent` --
-- atravessa a fachada. Enquanto ela tiver seis argumentos nao existe caminho
-- pelo qual uma foto do agente chegue ao banco, e o modo de falhar e o pior
-- que ha: nao estoura nada, a mensagem vira texto em silencio. A tela da dona
-- escapa porque `site_send_manual_message` chama `app.` direto, com os nove --
-- e foi por isso que o defeito sobreviveu: o unico caminho de midia que
-- alguem ja exercitou e justamente o que nao passa pela fachada.
--
-- O QUE ESTA MIGRATION NAO FAZ: mandar foto. Ela abre a porta. Hoje nenhuma
-- Edge Function preenche `p_media_storage_path` -- quando alguem escrever a
-- ferramenta que faz o agente mandar uma foto, ela vai encontrar a porta
-- aberta em vez de descobrir isto na primeira cliente.
--
-- ESTADO DOS BANCOS quando escrevi. ATENCAO AO REF, NUNCA AO NOME: os nomes
-- dos dois projetos no Supabase estao trocados de proposito, e o AMBIENTES.md
-- avisa disso. Uma versao anterior deste comentario leu o nome, inverteu os
-- dois e concluiu que faltava empurrar para o DEV -- que e o oposto.
--
--   dboygmtrzgsfcmoquegp  (nome diz "prod")  = DEV      vazio, 0 conversas
--   hjghwryhphgusefyivbl  (nome diz "dev")   = PRODUCAO Salao do William, 183
--                                                       mensagens, 1 conexao
--
-- Conferido pelo CONTEUDO, nao pelo rotulo: o DEV esta em 20260923234500 (com
-- esta fachada e a trava do `kind` ja aplicadas); a PRODUCAO parou na
-- 20260923164500 e esta CINCO atras -- 174500, 184500, 194500, esta e a
-- 234500. E na producao que os dois buracos do caminho de midia continuam
-- abertos, e e ela que tem as mensagens de verdade.
--
-- DUAS DECISOES QUE NAO SAO OBVIAS:
--
-- 1. A FACHADA DE SEIS E DERRUBADA ANTES. Acrescentar tres argumentos com
--    default NAO substitui a funcao antiga: cria uma segunda, e as duas passam
--    a atender uma chamada de seis argumentos. O Postgres nao desempata, ele
--    recusa com "function name is not unique" -- e quem quebraria seria o
--    texto, que hoje e a unica coisa que funciona. Deixar as duas vivas
--    trocaria um buraco de foto por um apagao de conversa.
--
-- 2. A GUARDA DO CAMINHO DESCE PARA A PORTA UNICA. `media_storage_path` aponta
--    uma pasta do balde privado `anexos`, e o worker baixa de la com a chave de
--    servico -- as policies do balde protegem o navegador, nao ele. Ate hoje
--    quem conferia que o caminho comeca pela pasta do proprio salao era so
--    `site_send_manual_message`; a fachada nova nasceria sem essa conferencia,
--    e ela e a porta de quem nao tem sessao de ninguem. Em vez de copiar a
--    guarda para a fachada -- a propria migration de 27/08 avisa que "guarda
--    duplicada e guarda que um dia diverge" --, ela desce para
--    `app.enqueue_outbound_message`, por onde todo envio passa, e sai de
--    `site_send_manual_message`. Mesma recusa, mesmo `reason`, um lugar so.

-- ---------------------------------------------------------------------------
-- A PORTA UNICA, AGORA COM A GUARDA DO CAMINHO.
--
-- Corpo identico ao de 20260923104500 (o acorda-o-worker-na-hora), com duas
-- mudancas: o caminho e limpo UMA vez em `v_caminho`, em vez de repetir
-- `nullif(trim(coalesce(...)))` em tres lugares, e a guarda de pasta entra
-- junto das outras validacoes de entrada, antes de qualquer escrita.
-- ---------------------------------------------------------------------------

create or replace function app.enqueue_outbound_message(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_body_text text,
  p_actor app.outbound_actor,
  p_idempotency_key text,
  p_actor_user_id uuid default null::uuid,
  p_media_storage_path text default null::text,
  p_media_mime_type text default null::text,
  p_media_filename text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_conversa record;
  v_endereco text;
  v_janela_aberta boolean;
  v_message_id uuid;
  v_outbox_id uuid;
  v_existente record;
  v_caminho text := nullif(trim(coalesce(p_media_storage_path, '')), '');
  v_mime text := nullif(trim(coalesce(p_media_mime_type, '')), '');
  v_nome_arquivo text := nullif(trim(coalesce(p_media_filename, '')), '');
  v_tem_midia boolean := v_caminho is not null;
  v_tipo text;
begin
  -- Midia sem legenda e legitima -- ninguem escreve nada ao mandar um audio.
  -- Texto sem corpo nao e.
  if not v_tem_midia and (p_body_text is null or length(trim(p_body_text)) = 0) then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_BODY');
  end if;
  if v_tem_midia and v_mime is null then
    return jsonb_build_object('ok', false, 'reason', 'MEDIA_MIME_REQUIRED');
  end if;

  -- O arquivo tem que estar na pasta do proprio salao. Quem baixa e o worker,
  -- com a chave de servico: para ele nao existe policy de balde, existe esta
  -- linha. (Estava so em `site_send_manual_message` ate 23/09/2026.)
  if v_tem_midia and v_caminho not like p_tenant_id::text || '/%' then
    return jsonb_build_object('ok', false, 'reason', 'MEDIA_PATH_FORBIDDEN');
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) not between 8 and 128 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_IDEMPOTENCY_KEY');
  end if;

  -- O interruptor vale para conversa de CLIENTE. Conversa do dono configurando
  -- o proprio salao nunca foi assunto dele. (Consertado em 18/09/2026.)
  if p_actor = 'AGENT'
     and not app.agent_automation_enabled(p_tenant_id)
     and not app.conversa_e_do_dono(p_conversation_id) then
    return jsonb_build_object('ok', false, 'reason', 'AGENT_AUTOMATION_DISABLED');
  end if;

  select o.id, o.message_id, o.status into v_existente
    from app.outbox_messages o
   where o.tenant_id = p_tenant_id
     and o.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'ok', true, 'duplicate', true,
      'outboxId', v_existente.id, 'messageId', v_existente.message_id,
      'status', v_existente.status
    );
  end if;

  select c.*, ch.address_normalized
    into v_conversa
    from app.crm_conversations c
    join app.crm_contact_channels ch
      on ch.tenant_id = c.tenant_id
     and ch.contact_id = c.contact_id
     and ch.provider = 'WHATSAPP'
   where c.tenant_id = p_tenant_id
     and c.id = p_conversation_id
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSATION_NOT_FOUND');
  end if;

  v_endereco := v_conversa.address_normalized;

  v_janela_aberta := v_conversa.last_inbound_at is not null
    and v_conversa.last_inbound_at > (statement_timestamp() - interval '24 hours');

  if not v_janela_aberta then
    return jsonb_build_object(
      'ok', false,
      'reason', 'SERVICE_WINDOW_CLOSED',
      'lastInboundAt', v_conversa.last_inbound_at,
      'hint', 'Fora da janela de 24h so e possivel reabrir com template aprovado.'
    );
  end if;

  v_tipo := case when v_tem_midia then 'MEDIA' else 'TEXT' end;

  insert into app.crm_messages (
    tenant_id, conversation_id, direction, provider_message_id,
    message_type, body_text, occurred_at, metadata_minimized
  )
  values (
    p_tenant_id, p_conversation_id, 'OUTBOUND', null,
    v_tipo, left(p_body_text, 4096), statement_timestamp(),
    jsonb_strip_nulls(jsonb_build_object(
      'actor', p_actor,
      'deliveryStatus', 'PENDING',
      'mediaMimeType', v_mime,
      'mediaFilename', v_nome_arquivo,
      'mediaStoragePath', v_caminho
    ))
  )
  returning id into v_message_id;

  insert into app.outbox_messages (
    tenant_id, conversation_id, message_id, channel_connection_id,
    recipient_address, kind, body_text, actor, actor_user_id, idempotency_key,
    media_storage_path, media_mime_type, media_filename
  )
  values (
    p_tenant_id, p_conversation_id, v_message_id, v_conversa.channel_connection_id,
    v_endereco, v_tipo, left(p_body_text, 4096), p_actor, p_actor_user_id,
    trim(p_idempotency_key),
    v_caminho, v_mime, v_nome_arquivo
  )
  returning id into v_outbox_id;

  update app.crm_conversations
     set last_message_at = greatest(last_message_at, statement_timestamp()),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id and id = p_conversation_id;

  -- A MENSAGEM ESTA NA FILA. ACORDA QUEM ENTREGA, AGORA.
  --
  -- O erro e engolido de proposito: se o disparo falhar, o cron pega no proximo
  -- minuto e a unica perda sao os segundos que a gente ja perdia antes. Deixar
  -- o erro subir derrubaria a gravacao da mensagem junto -- trocaria uma espera
  -- por uma conversa perdida.
  begin
    perform app.tick_worker('ENVIO', 'whatsapp-sender', '{}'::jsonb, 60000);
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'ok', true, 'duplicate', false,
    'outboxId', v_outbox_id, 'messageId', v_message_id, 'recipient', v_endereco
  );
end;
$function$;

comment on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid, text, text, text) is
  'Porta unica de saida de mensagem. Desde 23/09/2026 acorda o worker ENVIO na hora e confere, para todo chamador, que o anexo esta na pasta do proprio salao -- a guarda que antes so existia em site_send_manual_message.';

revoke all on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function app.enqueue_outbound_message(uuid, uuid, text, app.outbound_actor, text, uuid, text, text, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- A FACHADA, AGORA COM OS NOVE.
--
-- Primeiro derruba a de seis. Ver a decisao 1 no cabecalho: sem este drop, a
-- chamada de seis que o `whatsapp-agent` faz a cada resposta passa a ser
-- ambigua e a conversa de texto para de sair.
--
-- Os nomes dos parametros sao os mesmos da interna de proposito: o PostgREST
-- resolve a funcao pelo conjunto de chaves do JSON, entao o nome aqui e
-- contrato com a Edge Function, nao enfeite.
-- ---------------------------------------------------------------------------

drop function if exists public.enqueue_outbound_message(uuid, uuid, text, text, text, uuid);

create or replace function public.enqueue_outbound_message(
  p_tenant_id uuid,
  p_conversation_id uuid,
  p_body_text text,
  p_actor text,
  p_idempotency_key text,
  p_actor_user_id uuid default null::uuid,
  p_media_storage_path text default null::text,
  p_media_mime_type text default null::text,
  p_media_filename text default null::text
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select app.enqueue_outbound_message(
    p_tenant_id          => p_tenant_id,
    p_conversation_id    => p_conversation_id,
    p_body_text          => p_body_text,
    p_actor              => p_actor::app.outbound_actor,
    p_idempotency_key    => p_idempotency_key,
    p_actor_user_id      => p_actor_user_id,
    p_media_storage_path => p_media_storage_path,
    p_media_mime_type    => p_media_mime_type,
    p_media_filename     => p_media_filename
  );
$function$;

comment on function public.enqueue_outbound_message(uuid, uuid, text, text, text, uuid, text, text, text) is
  'Fachada de public para app.enqueue_outbound_message: recebe o ator como texto porque enum de schema nao exposto nao atravessa o PostgREST. Desde 23/09/2026 carrega tambem os tres argumentos de midia -- antes disso ela os descartava e toda foto virava texto.';

revoke all on function public.enqueue_outbound_message(uuid, uuid, text, text, text, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.enqueue_outbound_message(uuid, uuid, text, text, text, uuid, text, text, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- A PORTA DA TELA PARA DE CONFERIR O QUE A PORTA UNICA JA CONFERE.
--
-- Mesma assinatura, mesmo retorno, mesmo `reason` para caminho de fora da
-- pasta -- so que agora quem recusa e `app.enqueue_outbound_message`. Ver a
-- decisao 2 no cabecalho.
-- ---------------------------------------------------------------------------

create or replace function public.site_send_manual_message(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_conversation_id uuid,
  message_text           text,
  idempotency_key        text,
  media_storage_path     text default null,
  media_mime_type        text default null,
  media_filename         text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  if coalesce(length(message_text), 0) > 4096 then
    return jsonb_build_object('ok', false, 'reason', 'BODY_TOO_LONG');
  end if;

  return app.enqueue_outbound_message(
    p_tenant_id          => target_tenant_id,
    p_conversation_id    => target_conversation_id,
    p_body_text          => message_text,
    p_actor              => 'HUMAN'::app.outbound_actor,
    p_idempotency_key    => idempotency_key,
    p_media_storage_path => media_storage_path,
    p_media_mime_type    => media_mime_type,
    p_media_filename     => media_filename
  );
end;
$function$;

revoke all on function public.site_send_manual_message(text, text, uuid, uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.site_send_manual_message(text, text, uuid, uuid, text, text, text, text, text)
  to service_role;
