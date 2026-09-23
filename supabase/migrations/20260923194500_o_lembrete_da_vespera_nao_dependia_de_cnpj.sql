-- O LEMBRETE DA VESPERA NAO DEPENDIA DE CNPJ.
--
-- 23/09/2026. Ontem eu escrevi, na migration 20260923184500, que lembrete de
-- vespera "depende de modelo aprovado pela Meta, que depende do App Review", e
-- mandei o Eddy dizer ao dono que "ainda nao da". As duas frases estao erradas,
-- e eu as escrevi sem ter lido a documentacao.
--
-- O QUE A DOCUMENTACAO DA META DIZ, conferido hoje na fonte:
--
--   * Portfolio nao verificado: 250 modelos por WABA. O salao precisa de um.
--   * "Newly created business portfolios have a messaging limit of 250"
--     destinatarios unicos por 24h. Um salao manda algo entre 20 e 40.
--   * "Standard access does not require app review", e vale para quem tem
--     funcao no app.
--
-- O que exige verificacao (e portanto CNPJ) e outra coisa: Embedded Signup,
-- coexistencia ("You must already be a Solution Partner or Tech Provider"),
-- migrar numero entre portfolios, selo verde, 6.000 modelos. Nada disso e
-- necessario para mandar lembrete no numero da propria casa.
--
-- POR QUE ISSO NUNCA FUNCIONOU, ENTAO: porque ninguem construiu. O
-- `whatsapp-sender` so monta corpo de texto e de midia. Nao existe `type:
-- "template"` em lugar nenhum do repositorio. A tabela `outbox_messages`
-- nasceu em 20/08 com `kind = 'TEMPLATE'`, `template_name`,
-- `template_language` e `template_params` -- e as quatro colunas nunca
-- receberam uma linha. O desenho estava certo e a mao nunca veio.
--
-- ESTA MIGRATION TRAZ A MAO. O que ela NAO faz: criar o modelo na Meta. Isso e
-- na tela do WhatsApp Manager, com a conta da dona, e nenhuma automacao minha
-- entra la.

-- ---------------------------------------------------------------------------
-- CONSERTO DE PASSAGEM: A TRAVA DO `kind` NUNCA ACEITOU 'MEDIA'.
--
-- `outbox_messages_kind_check` diz `kind in ('TEXT','TEMPLATE')`, mas
-- `enqueue_outbound_message` grava 'MEDIA' desde 27/08 quando ha foto. Em 102
-- linhas enviadas, zero sao MEDIA -- o caminho nunca foi exercitado, entao a
-- trava nunca disparou. A primeira foto que o agente tentasse mandar morreria
-- no insert, e a mensagem inteira se perderia junto.
--
-- ATENCAO, E ISSO PRECISA ESTAR ESCRITO: consertar a trava NAO faz foto
-- funcionar. Ha um segundo buraco no mesmo caminho -- a fachada
-- `public.enqueue_outbound_message` tem seis argumentos e nenhum de midia,
-- entao descarta `p_media_storage_path` antes de chegar na funcao interna.
-- Arrumo a trava porque estou reescrevendo ela para o TEMPLATE de qualquer
-- forma; a fachada fica para uma tarefa propria, com teste de ponta a ponta.

alter table app.outbox_messages drop constraint if exists outbox_messages_kind_check;
alter table app.outbox_messages
  add constraint outbox_messages_kind_check
  check (kind in ('TEXT', 'MEDIA', 'TEMPLATE'));

alter table app.outbox_messages drop constraint if exists outbox_kind_payload_check;
alter table app.outbox_messages
  add constraint outbox_kind_payload_check check (
    (kind = 'TEXT' and body_text is not null and length(trim(body_text)) > 0)
    or (kind = 'MEDIA' and media_storage_path is not null)
    or (kind = 'TEMPLATE' and template_name is not null and template_language is not null)
  );

-- ---------------------------------------------------------------------------
-- O REGISTRO DOS MODELOS APROVADOS.
--
-- O nome do modelo na Meta e por WABA, escolhido por quem o criou, e minusculo
-- com underscore. Nao da para o codigo chutar: o salao da Duda pode ter
-- `lembrete_agendamento` e o do William `lembrete_horario`. Entao o codigo fala
-- por CODIGO interno (LEMBRETE_VESPERA) e a tabela traduz para o nome real.
--
-- `status` existe porque modelo aprovado pode ser PAUSADO pela Meta depois, por
-- qualidade. Mandar para um modelo pausado devolve erro e queima o numero.
-- ---------------------------------------------------------------------------

create table if not exists app.message_templates (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references app.tenants(id) on delete cascade,
  code          text not null check (code ~ '^[A-Z][A-Z0-9_]{2,40}$'),
  template_name text not null check (template_name ~ '^[a-z0-9_]{1,512}$'),
  language      text not null default 'pt_BR' check (language ~ '^[a-z]{2}(_[A-Z]{2})?$'),
  category      text not null default 'UTILITY'
                  check (category in ('UTILITY', 'MARKETING', 'AUTHENTICATION')),
  param_count   integer not null default 0 check (param_count between 0 and 10),
  preview       text,
  status        text not null default 'APPROVED'
                  check (status in ('APPROVED', 'PENDING', 'REJECTED', 'PAUSED')),
  created_at    timestamptz not null default statement_timestamp(),
  updated_at    timestamptz not null default statement_timestamp(),
  unique (tenant_id, code)
);

comment on table app.message_templates is
  'Traducao de codigo interno para o nome real do modelo aprovado na Meta, que e por WABA. Sem linha aqui, o lembrete e pulado com motivo visivel em vez de falhar no Graph.';

alter table app.message_templates enable row level security;

create or replace function app.registrar_modelo_aprovado(
  p_tenant_id     uuid,
  p_code          text,
  p_template_name text,
  p_param_count   integer,
  p_language      text default 'pt_BR',
  p_category      text default 'UTILITY',
  p_preview       text default null,
  p_status        text default 'APPROVED'
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id uuid;
begin
  insert into app.message_templates (
    tenant_id, code, template_name, language, category, param_count, preview, status
  ) values (
    p_tenant_id, upper(trim(p_code)), lower(trim(p_template_name)),
    trim(p_language), upper(trim(p_category)), p_param_count,
    nullif(trim(coalesce(p_preview, '')), ''), upper(trim(p_status))
  )
  on conflict (tenant_id, code) do update
     set template_name = excluded.template_name,
         language      = excluded.language,
         category      = excluded.category,
         param_count   = excluded.param_count,
         preview       = coalesce(excluded.preview, app.message_templates.preview),
         status        = excluded.status,
         updated_at    = statement_timestamp()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$fn$;

revoke all on function app.registrar_modelo_aprovado(uuid, text, text, integer, text, text, text, text)
  from public, anon, authenticated;
grant execute on function app.registrar_modelo_aprovado(uuid, text, text, integer, text, text, text, text)
  to service_role;

create or replace function public.registrar_modelo_aprovado(
  p_tenant_id uuid, p_code text, p_template_name text, p_param_count integer,
  p_language text default 'pt_BR', p_category text default 'UTILITY',
  p_preview text default null, p_status text default 'APPROVED'
) returns jsonb language sql security definer set search_path to ''
as $$ select app.registrar_modelo_aprovado(p_tenant_id, p_code, p_template_name,
       p_param_count, p_language, p_category, p_preview, p_status); $$;
revoke all on function public.registrar_modelo_aprovado(uuid, text, text, integer, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.registrar_modelo_aprovado(uuid, text, text, integer, text, text, text, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- A QUE HORAS O LEMBRETE SAI.
--
-- 18h da vespera e o padrao porque e quando a cliente ja saiu do trabalho e
-- ainda da tempo de remarcar. Fica em `agent_scope` porque e a mesma pergunta
-- ("o que voce quer que eu faca") -- nao merece tabela propria.
-- ---------------------------------------------------------------------------

alter table app.agent_scope
  add column if not exists lembrete_hora_local integer not null default 18;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'agent_scope_hora_valida'
  ) then
    alter table app.agent_scope
      add constraint agent_scope_hora_valida
      check (lembrete_hora_local between 0 and 23);
  end if;
end $$;

comment on column app.agent_scope.lembra_da_vespera is
  'Se o agente manda lembrete na vespera. Nao depende de App Review nem de CNPJ -- depende de ter um modelo aprovado em app.message_templates. (Corrigido em 23/09/2026: o comentario anterior afirmava o contrario, sem fonte.)';

-- ---------------------------------------------------------------------------
-- O QUE FOI DECIDIDO SOBRE CADA AGENDAMENTO.
--
-- Uma linha por agendamento, sempre -- inclusive quando NAO deu para mandar.
-- Lembrete que nao saiu em silencio e o mesmo que lembrete inexistente, e a
-- dona so descobriria pela cliente que faltou.
-- ---------------------------------------------------------------------------

create table if not exists app.appointment_reminders (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references app.tenants(id) on delete cascade,
  appointment_id uuid not null references app.appointments(id) on delete cascade,
  kind           text not null default 'VESPERA' check (kind in ('VESPERA')),
  scheduled_for  timestamptz not null,
  decided_at     timestamptz not null default statement_timestamp(),
  status         text not null check (status in ('ENFILEIRADO', 'PULADO', 'FALHOU')),
  skip_reason    text,
  outbox_id      uuid,
  unique (tenant_id, appointment_id, kind)
);

comment on table app.appointment_reminders is
  'Uma linha por agendamento decidido, inclusive os pulados. skip_reason e o que a dona le quando pergunta "por que a cliente nao recebeu?".';

create index if not exists appointment_reminders_tenant_idx
  on app.appointment_reminders (tenant_id, decided_at desc);

alter table app.appointment_reminders enable row level security;

-- ---------------------------------------------------------------------------
-- ENFILEIRAR UM TEMPLATE.
--
-- Irma de `enqueue_outbound_message`, com UMA diferenca deliberada: nao checa a
-- janela de 24h. Essa e a razao de existir do template -- e exatamente o que a
-- propria `enqueue_outbound_message` sugere quando recusa, na dica que ela
-- devolve desde 20/08: "Fora da janela de 24h so e possivel reabrir com
-- template aprovado."
--
-- O interruptor de automacao CONTINUA valendo. Quem puxou o freio de emergencia
-- quer o salao calado, e lembrete automatico e justamente o tipo de mensagem
-- que nao pode escapar de um freio.
-- ---------------------------------------------------------------------------

create or replace function app.enqueue_outbound_template(
  p_tenant_id       uuid,
  p_conversation_id uuid,
  p_template_code   text,
  p_params          jsonb,
  p_idempotency_key text,
  p_preview         text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_modelo     record;
  v_conversa   record;
  v_message_id uuid;
  v_outbox_id  uuid;
  v_existente  record;
  v_params     jsonb := coalesce(p_params, '[]'::jsonb);
  v_quantos    integer;
begin
  if p_idempotency_key is null
     or length(trim(p_idempotency_key)) not between 8 and 128 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_IDEMPOTENCY_KEY');
  end if;

  if jsonb_typeof(v_params) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'PARAMS_NAO_E_LISTA');
  end if;

  if not app.agent_automation_enabled(p_tenant_id) then
    return jsonb_build_object('ok', false, 'reason', 'AGENT_AUTOMATION_DISABLED');
  end if;

  -- Idempotencia antes de tudo: o agendador roda de 15 em 15 minutos e vai
  -- encontrar o mesmo agendamento varias vezes no mesmo dia.
  select o.id, o.message_id, o.status into v_existente
    from app.outbox_messages o
   where o.tenant_id = p_tenant_id
     and o.idempotency_key = trim(p_idempotency_key);
  if found then
    return jsonb_build_object(
      'ok', true, 'duplicate', true,
      'outboxId', v_existente.id, 'messageId', v_existente.message_id,
      'status', v_existente.status
    );
  end if;

  select t.* into v_modelo
    from app.message_templates t
   where t.tenant_id = p_tenant_id
     and t.code = upper(trim(p_template_code));

  if not found then
    return jsonb_build_object(
      'ok', false, 'reason', 'MODELO_NAO_REGISTRADO',
      'codigo', upper(trim(p_template_code)),
      'comoResolver', 'Crie o modelo no WhatsApp Manager e registre com registrar_modelo_aprovado.');
  end if;

  if v_modelo.status <> 'APPROVED' then
    return jsonb_build_object(
      'ok', false, 'reason', 'MODELO_NAO_APROVADO', 'status', v_modelo.status);
  end if;

  v_quantos := jsonb_array_length(v_params);
  if v_quantos <> v_modelo.param_count then
    -- A Meta recusa a mensagem inteira quando a contagem nao bate, e o erro
    -- dela nao diz qual modelo era. Melhor recusar aqui, com o numero.
    return jsonb_build_object(
      'ok', false, 'reason', 'QUANTIDADE_DE_PARAMETROS_ERRADA',
      'esperado', v_modelo.param_count, 'recebido', v_quantos);
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

  -- O corpo legivel e so para a tela e para o historico. Quem decide o texto
  -- de verdade e a Meta, a partir do modelo aprovado.
  insert into app.crm_messages (
    tenant_id, conversation_id, direction, provider_message_id,
    message_type, body_text, occurred_at, metadata_minimized
  )
  values (
    p_tenant_id, p_conversation_id, 'OUTBOUND', null,
    'TEMPLATE', left(coalesce(p_preview, v_modelo.preview, v_modelo.template_name), 4096),
    statement_timestamp(),
    jsonb_build_object(
      'actor', 'SYSTEM',
      'deliveryStatus', 'PENDING',
      'templateCode', v_modelo.code,
      'templateName', v_modelo.template_name
    )
  )
  returning id into v_message_id;

  insert into app.outbox_messages (
    tenant_id, conversation_id, message_id, channel_connection_id,
    recipient_address, kind, body_text, template_name, template_language,
    template_params, actor, idempotency_key
  )
  values (
    p_tenant_id, p_conversation_id, v_message_id, v_conversa.channel_connection_id,
    v_conversa.address_normalized, 'TEMPLATE',
    left(coalesce(p_preview, v_modelo.preview, ''), 4096),
    v_modelo.template_name, v_modelo.language, v_params, 'SYSTEM',
    trim(p_idempotency_key)
  )
  returning id into v_outbox_id;

  update app.crm_conversations
     set last_message_at = greatest(last_message_at, statement_timestamp()),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id and id = p_conversation_id;

  -- Mesmo acordar de 23/09: o erro e engolido porque o cron de 30 segundos
  -- pega logo depois, e deixar o erro subir desfaria a gravacao da mensagem.
  begin
    perform app.tick_worker('ENVIO', 'whatsapp-sender', '{}'::jsonb, 60000);
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'ok', true, 'outboxId', v_outbox_id, 'messageId', v_message_id,
    'templateName', v_modelo.template_name);
end;
$fn$;

revoke all on function app.enqueue_outbound_template(uuid, uuid, text, jsonb, text, text)
  from public, anon, authenticated;
grant execute on function app.enqueue_outbound_template(uuid, uuid, text, jsonb, text, text)
  to service_role;

create or replace function public.enqueue_outbound_template(
  p_tenant_id uuid, p_conversation_id uuid, p_template_code text,
  p_params jsonb, p_idempotency_key text, p_preview text default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.enqueue_outbound_template(p_tenant_id, p_conversation_id,
       p_template_code, p_params, p_idempotency_key, p_preview); $$;
revoke all on function public.enqueue_outbound_template(uuid, uuid, text, jsonb, text, text)
  from public, anon, authenticated;
grant execute on function public.enqueue_outbound_template(uuid, uuid, text, jsonb, text, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- O AGENDADOR.
--
-- Roda dentro do banco, de 15 em 15 minutos. Nao precisa de Edge Function nem
-- de `worker_endpoints` -- e por isso funciona no dev, que sobe inerte.
--
-- TRES DECISOES DE HORARIO, e as tres sao sobre a cliente, nao sobre o codigo:
--
-- 1. O fuso e o da UNIDADE, nao o do servidor. `units.timezone` existe desde o
--    comeco. Servidor em UTC mandaria o lembrete das 18h as 15h.
-- 2. So sai entre 8h e 20h locais. Cliente que agenda as 23h para as 9h do dia
--    seguinte tem o lembrete empurrado para as 8h, nao acordada na hora.
-- 3. So sai se ainda faltar mais de uma hora. Lembrete que chega quarenta
--    minutos antes nao e lembrete, e susto.
-- ---------------------------------------------------------------------------

create or replace function app.agendar_lembretes_da_vespera(p_limite integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_linha      record;
  v_envio_utc  timestamptz;
  v_local      timestamp;
  v_fone       text;
  v_conversa   uuid;
  v_resultado  jsonb;
  v_motivo     text;
  v_nome       text;
  v_enfileirados integer := 0;
  v_pulados      integer := 0;
begin
  if p_limite is null or p_limite < 1 or p_limite > 1000 then
    p_limite := 200;
  end if;

  for v_linha in
    select a.id, a.tenant_id, a.starts_at, a.customer_label, a.external_contact_ref,
           u.timezone, sc.lembrete_hora_local, t.display_name as salao
      from app.appointments a
      join app.units u          on u.id = a.unit_id
      join app.agent_scope sc   on sc.tenant_id = a.tenant_id
      join app.tenants t        on t.id = a.tenant_id
     where a.status = 'CONFIRMED'
       and sc.lembra_da_vespera
       and a.starts_at > statement_timestamp() + interval '1 hour'
       and a.starts_at < statement_timestamp() + interval '3 days'
       and not exists (
         select 1 from app.appointment_reminders r
          where r.tenant_id = a.tenant_id
            and r.appointment_id = a.id
            and r.kind = 'VESPERA'
       )
     order by a.starts_at
     limit p_limite
  loop
    -- O momento do envio: vespera do dia local do atendimento, na hora escolhida.
    v_local := v_linha.starts_at at time zone v_linha.timezone;
    v_envio_utc := (date_trunc('day', v_local)
                    - interval '1 day'
                    + make_interval(hours => v_linha.lembrete_hora_local))
                   at time zone v_linha.timezone;

    -- Ainda nao chegou a hora. Sai sem gravar nada: a linha em
    -- appointment_reminders e definitiva, e gravar agora fecharia a porta.
    continue when statement_timestamp() < v_envio_utc;

    -- Fora da faixa civilizada. Volta no proximo giro do cron.
    continue when extract(hour from (statement_timestamp() at time zone v_linha.timezone))
                  not between 8 and 20;

    v_motivo := null;
    v_resultado := null;
    v_conversa := null;

    v_fone := nullif(trim(coalesce(v_linha.external_contact_ref, '')), '');

    if v_fone is null then
      v_motivo := 'SEM_TELEFONE';
    else
      select c.id into v_conversa
        from app.crm_conversations c
        join app.crm_contact_channels ch
          on ch.tenant_id = c.tenant_id
         and ch.contact_id = c.contact_id
         and ch.provider = 'WHATSAPP'
       where c.tenant_id = v_linha.tenant_id
         and ch.address_normalized = v_fone
       order by c.last_message_at desc nulls last
       limit 1;

      if v_conversa is null then
        v_motivo := 'SEM_CONVERSA';
      end if;
    end if;

    if v_motivo is null then
      -- Primeiro nome so. "Oi Maria Aparecida da Silva" nao e como se fala.
      v_nome := split_part(trim(coalesce(v_linha.customer_label, '')), ' ', 1);
      if v_nome = '' then v_nome := 'tudo bem'; end if;

      v_resultado := app.enqueue_outbound_template(
        v_linha.tenant_id,
        v_conversa,
        'LEMBRETE_VESPERA',
        jsonb_build_array(
          v_nome,
          to_char(v_local, 'DD/MM'),
          to_char(v_local, 'HH24:MI'),
          v_linha.salao
        ),
        'lembrete:' || v_linha.id::text,
        format('Oi %s! Lembrando do seu horario amanha, %s, as %s, no %s.',
               v_nome, to_char(v_local, 'DD/MM'), to_char(v_local, 'HH24:MI'), v_linha.salao)
      );

      if not coalesce((v_resultado ->> 'ok')::boolean, false) then
        v_motivo := coalesce(v_resultado ->> 'reason', 'ERRO_DESCONHECIDO');
      end if;
    end if;

    insert into app.appointment_reminders (
      tenant_id, appointment_id, kind, scheduled_for, status, skip_reason, outbox_id
    ) values (
      v_linha.tenant_id, v_linha.id, 'VESPERA', v_envio_utc,
      case when v_motivo is null then 'ENFILEIRADO' else 'PULADO' end,
      v_motivo,
      case when v_motivo is null then (v_resultado ->> 'outboxId')::uuid else null end
    )
    on conflict (tenant_id, appointment_id, kind) do nothing;

    if v_motivo is null then
      v_enfileirados := v_enfileirados + 1;
    else
      v_pulados := v_pulados + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'enfileirados', v_enfileirados, 'pulados', v_pulados);
end;
$fn$;

comment on function app.agendar_lembretes_da_vespera(integer) is
  'Decide o lembrete de vespera de cada agendamento confirmado. Grava sempre, inclusive quando pula, com o motivo.';

revoke all on function app.agendar_lembretes_da_vespera(integer) from public, anon, authenticated;
grant execute on function app.agendar_lembretes_da_vespera(integer) to service_role;

create or replace function public.agendar_lembretes_da_vespera(p_limite integer default 200)
returns jsonb language sql security definer set search_path to ''
as $$ select app.agendar_lembretes_da_vespera(p_limite); $$;
revoke all on function public.agendar_lembretes_da_vespera(integer) from public, anon, authenticated;
grant execute on function public.agendar_lembretes_da_vespera(integer) to service_role;

-- ---------------------------------------------------------------------------
-- O CONSUMIDOR PRECISA ENXERGAR AS COLUNAS DO TEMPLATE.
--
-- `claim_outbox_batch` reserva o lote e devolve o que o sender precisa para
-- montar o corpo. Ela nunca devolveu `template_name` -- entao mesmo que uma
-- linha TEMPLATE existisse, o sender a receberia sem nome de modelo e mandaria
-- um corpo vazio.
--
-- `create or replace` NAO muda tipo de retorno de funcao `returns table`. Isso
-- custou um push ontem, 22/09. O drop vem primeiro, de proposito.
-- ---------------------------------------------------------------------------

drop function if exists public.claim_outbox_batch(integer);
drop function if exists app.claim_outbox_batch(integer);

create function app.claim_outbox_batch(p_limit integer default 20)
returns table (
  id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text,
  body_text text, attempts integer, media_storage_path text, media_mime_type text,
  media_filename text, media_provider_id text, credential_ref text, connection_id uuid,
  template_name text, template_language text, template_params jsonb
)
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'p_limit deve estar entre 1 e 200, recebido %', p_limit;
  end if;

  return query
  with reservados as (
    select o.id
      from app.outbox_messages o
     where o.status = 'PENDING'
       and o.next_attempt_at <= statement_timestamp()
     order by o.next_attempt_at, o.created_at, o.id
     limit p_limit
       for update skip locked
  ),
  atualizados as (
    update app.outbox_messages o
       set status = 'SENDING',
           attempts = o.attempts + 1,
           updated_at = statement_timestamp()
      from reservados r
     where o.id = r.id
    returning o.id, o.tenant_id, o.channel_connection_id,
              o.recipient_address, o.kind, o.body_text, o.attempts,
              o.media_storage_path, o.media_mime_type, o.media_filename,
              o.media_provider_id, o.created_at,
              o.template_name, o.template_language, o.template_params
  )
  select a.id, a.tenant_id, c.external_sender_id,
         a.recipient_address, a.kind, a.body_text, a.attempts,
         a.media_storage_path, a.media_mime_type, a.media_filename,
         a.media_provider_id, c.credential_ref, c.id,
         a.template_name, a.template_language, a.template_params
    from atualizados a
    left join app.channel_connections c on c.id = a.channel_connection_id
   order by a.created_at, a.id;
end;
$fn$;

revoke all on function app.claim_outbox_batch(integer) from public, anon, authenticated;
grant execute on function app.claim_outbox_batch(integer) to service_role;

create function public.claim_outbox_batch(p_limit integer default 20)
returns table (
  id uuid, tenant_id uuid, sender_id text, recipient_address text, kind text,
  body_text text, attempts integer, media_storage_path text, media_mime_type text,
  media_filename text, media_provider_id text, credential_ref text, connection_id uuid,
  template_name text, template_language text, template_params jsonb
)
language sql
security definer
set search_path to ''
as $$ select * from app.claim_outbox_batch(p_limit); $$;
revoke all on function public.claim_outbox_batch(integer) from public, anon, authenticated;
grant execute on function public.claim_outbox_batch(integer) to service_role;

-- ---------------------------------------------------------------------------
-- O RELOGIO DO LEMBRETE.
--
-- Quinze minutos e suficiente: o lembrete tem uma janela de horas, nao de
-- segundos. Cron mais apertado so gastaria giro a toa.
-- ---------------------------------------------------------------------------

select cron.unschedule('lembrete-da-vespera')
 where exists (select 1 from cron.job where jobname = 'lembrete-da-vespera');

select cron.schedule('lembrete-da-vespera', '*/15 * * * *', $cron$
  select app.agendar_lembretes_da_vespera(200);
$cron$);

-- ---------------------------------------------------------------------------
-- O EDDY PRECISA PARAR DE DIZER QUE NAO DA.
--
-- Ontem eu mandei ele dizer "ainda nao da, esta sendo liberado". Era falso, e
-- o dono que acreditasse nisso desistiria da unica funcao que mais vende o
-- produto.
-- ---------------------------------------------------------------------------

update app.agent_prompt_blocks
   set body = replace(
         body,
         'Se ele perguntar por lembrete de véspera: diga que ainda não dá, que está sendo liberado, e que você avisa quando estiver pronto. Não prometa data.',
         'Lembrete de véspera funciona. O salão precisa de um modelo de mensagem aprovado pela Meta — quem cria isso é a Eduarda, uma vez por salão, e leva minutos. Se ele quiser, marque que quer e diga que vai ser ligado junto com o número dele. Não invente prazo de horas.'),
       updated_at = statement_timestamp()
 where agent = 'DONO'
   and body like '%ainda não dá, que está sendo liberado%';
