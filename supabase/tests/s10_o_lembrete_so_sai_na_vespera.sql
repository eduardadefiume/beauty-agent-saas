-- S10: o lembrete só sai na véspera, e o que não sai deixa rastro.
--
-- 23/09/2026. O lembrete de véspera nunca existiu porque ninguém construiu o
-- caminho do template -- e `plpgsql` não valida corpo de função na criação,
-- então uma coluna errada num insert só apareceria no primeiro lembrete real,
-- de uma cliente real. Este teste é o que impede isso.
--
-- As quatro coisas que ele tranca:
--
--   1. atendimento AMANHÃ, passada a hora escolhida  -> enfileira TEMPLATE,
--      com nome, idioma e os quatro parâmetros certos;
--   2. atendimento HOJE -> pula com AGENDADO_SEM_VESPERA. O texto aprovado diz
--      "amanhã"; mandá-lo no próprio dia seria mentir para a cliente. Este é o
--      furo que quase passou: a guarda antiga era `now() >= momento_do_envio`,
--      e quem marca no próprio dia tem esse momento no passado;
--   3. atendimento daqui a TRÊS DIAS -> não grava nada. A linha em
--      appointment_reminders é definitiva, e gravar cedo fecharia a porta;
--   4. sem modelo registrado -> pula com MODELO_NAO_REGISTRADO em vez de
--      estourar no Graph da Meta.
--
-- POR QUE O FUSO É ESCOLHIDO E NÃO FIXO. O agendador só envia entre 8h e 21h
-- locais. Com fuso fixo, este teste passaria de dia e falharia de madrugada --
-- e teste que depende da hora em que roda não prova nada. Então ele procura um
-- `Etc/GMT*` onde AGORA seja meio-dia. São fusos sem horário de verão, então a
-- conta não muda duas vezes por ano.
--
-- Roda só contra o projeto DEV, em transação, e desfaz tudo no fim.

begin;

do $$
declare
  v_tz        text;
  v_hoje      date;
  v_tenant    uuid;
  v_unidade   uuid;
  v_conexao   uuid;
  v_rascunho  uuid;
  v_versao    uuid;
  v_servico   uuid;
  v_contato   uuid;
  v_conversa  uuid;
  v_ap_amanha uuid;
  v_ap_hoje   uuid;
  v_ap_longe  uuid;
  v_resultado jsonb;
  v_outbox    record;
  v_status    text;
  v_motivo    text;
  v_quantas   integer;
begin
  -- ---------------------------------------------------------------------
  -- Um fuso onde agora é meio-dia: dentro da faixa civilizada em qualquer
  -- horário em que este teste for executado.
  -- ---------------------------------------------------------------------
  select name into v_tz
    from pg_timezone_names
   where name like 'Etc/GMT%'
     and extract(hour from (statement_timestamp() at time zone name)) = 12
   order by name
   limit 1;

  if v_tz is null then
    raise exception 'S10 nao achou fuso Etc/GMT com meio-dia agora';
  end if;

  v_hoje := (statement_timestamp() at time zone v_tz)::date;

  -- ---------------------------------------------------------------------
  -- O salão inteiro, montado do zero. Os outros testes desta pasta pedem uma
  -- conexão pré-existente; este não, porque o DEV sobe vazio e um teste que
  -- só roda em banco povoado não roda quando mais importa.
  -- ---------------------------------------------------------------------
  insert into app.tenants (legal_name, display_name, slug)
  values ('S10 Salao de Teste', 'S10 Salao', 'v10-salao-de-teste-' || substr(gen_random_uuid()::text, 1, 8))
  returning id into v_tenant;

  insert into app.units (tenant_id, name, timezone)
  values (v_tenant, 'S10 Unidade', v_tz)
  returning id into v_unidade;

  insert into app.configuration_drafts (tenant_id, unit_id)
  values (v_tenant, v_unidade)
  returning id into v_rascunho;

  -- `snapshot_hash` é validado como sha256 em hexadecimal (64 caracteres):
  -- qualquer rótulo inventado é recusado pela restrição da tabela.
  insert into app.configuration_versions (
    tenant_id, unit_id, source_draft_id, version_number, snapshot, snapshot_hash
  ) values (
    v_tenant, v_unidade, v_rascunho, 1, '{}'::jsonb, encode(sha256('s10'::bytea), 'hex')
  ) returning id into v_versao;

  insert into app.services (tenant_id, configuration_draft_id, name)
  values (v_tenant, v_rascunho, 'Escova')
  returning id into v_servico;

  insert into app.channel_connections (
    tenant_id, channel, external_account_id, external_sender_id, purpose
  ) values (
    v_tenant, 'WHATSAPP', 's10-waba', 's10-sender', 'CLIENTE'
  ) returning id into v_conexao;

  -- O FREIO DE EMERGÊNCIA FICA PUXADO DE PROPÓSITO.
  --
  -- Até 23/09 o lembrete respeitava este interruptor, e com ele em `false`
  -- tudo virava AGENT_AUTOMATION_DISABLED. A Eduarda decidiu o contrário, e o
  -- argumento é melhor que o meu: o freio existe para calar o AGENTE quando
  -- ele escorrega, e lembrete de véspera não é o agente falando -- é texto
  -- fixo, aprovado pela Meta, sobre um horário que a própria cliente marcou.
  --
  -- Deixar `false` aqui faz este teste provar a decisão, e não só conviver com
  -- ela: se alguém devolver a trava, o caso de amanhã quebra na hora.
  insert into app.agent_automation (tenant_id, enabled) values (v_tenant, false);

  insert into app.crm_contacts (tenant_id, unit_id, display_name, status)
  values (v_tenant, v_unidade, 'Rayana Teste', 'ACTIVE')
  returning id into v_contato;

  insert into app.crm_contact_channels (
    tenant_id, contact_id, channel_connection_id, provider, address_normalized, is_primary
  ) values (
    v_tenant, v_contato, v_conexao, 'WHATSAPP', '5500000001000', true
  );

  insert into app.crm_conversations (
    tenant_id, unit_id, contact_id, channel_connection_id,
    external_conversation_ref, status, last_message_at
  ) values (
    v_tenant, v_unidade, v_contato, v_conexao, '5500000001000', 'OPEN', statement_timestamp()
  ) returning id into v_conversa;

  -- O dono quer lembrete, e escolheu 9h. Como agora é meio-dia local, a hora
  -- já passou -- então o caso de amanhã deve disparar neste mesmo giro.
  insert into app.agent_scope (tenant_id, marca_horario, lembra_da_vespera, lembrete_hora_local, respondido_em)
  values (v_tenant, true, true, 9, statement_timestamp());

  -- ---------------------------------------------------------------------
  -- Três atendimentos, um por caso.
  -- ---------------------------------------------------------------------
  -- `correlation_id` exige no mínimo 8 caracteres: nomes curtos demais são
  -- recusados pela restrição da tabela, não pelo agendador.
  insert into app.appointments (
    tenant_id, unit_id, configuration_version_id, service_id,
    starts_at, ends_at, status, plan, correlation_id,
    customer_label, external_contact_ref
  ) values (
    v_tenant, v_unidade, v_versao, v_servico,
    ((v_hoje + 1) + time '14:00') at time zone v_tz,
    ((v_hoje + 1) + time '15:00') at time zone v_tz,
    'CONFIRMED', '{"steps":[]}'::jsonb, 's10-caso-amanha',
    'Rayana Teste', '5500000001000'
  ) returning id into v_ap_amanha;

  insert into app.appointments (
    tenant_id, unit_id, configuration_version_id, service_id,
    starts_at, ends_at, status, plan, correlation_id,
    customer_label, external_contact_ref
  ) values (
    v_tenant, v_unidade, v_versao, v_servico,
    (v_hoje + time '23:00') at time zone v_tz,
    (v_hoje + time '23:30') at time zone v_tz,
    'CONFIRMED', '{"steps":[]}'::jsonb, 's10-caso-hoje-mesmo',
    'Rayana Teste', '5500000001000'
  ) returning id into v_ap_hoje;

  insert into app.appointments (
    tenant_id, unit_id, configuration_version_id, service_id,
    starts_at, ends_at, status, plan, correlation_id,
    customer_label, external_contact_ref
  ) values (
    v_tenant, v_unidade, v_versao, v_servico,
    ((v_hoje + 3) + time '14:00') at time zone v_tz,
    ((v_hoje + 3) + time '15:00') at time zone v_tz,
    'CONFIRMED', '{"steps":[]}'::jsonb, 's10-caso-tres-dias',
    'Rayana Teste', '5500000001000'
  ) returning id into v_ap_longe;

  -- ---------------------------------------------------------------------
  -- CASO 4 PRIMEIRO: sem modelo registrado, ele pula dizendo por quê.
  -- ---------------------------------------------------------------------
  v_resultado := app.agendar_lembretes_da_vespera(50);

  select r.status, r.skip_reason into v_status, v_motivo
    from app.appointment_reminders r
   where r.appointment_id = v_ap_amanha;

  if v_status is distinct from 'PULADO' or v_motivo is distinct from 'MODELO_NAO_REGISTRADO' then
    raise exception 'S10/4: sem modelo esperava PULADO/MODELO_NAO_REGISTRADO, veio %/%',
      v_status, v_motivo;
  end if;

  -- Limpa a decisão para repetir o mesmo agendamento agora COM modelo. Fora do
  -- teste isso nunca acontece: a linha é definitiva de propósito.
  delete from app.appointment_reminders where tenant_id = v_tenant;

  -- ---------------------------------------------------------------------
  -- Agora com o modelo aprovado registrado.
  -- ---------------------------------------------------------------------
  perform app.registrar_modelo_aprovado(
    v_tenant, 'LEMBRETE_VESPERA', 'lembrete_vespera', 4, 'pt_BR', 'UTILITY',
    'Oi {1}! Lembrando do seu horario amanha, {2}, as {3}, no {4}.'
  );

  v_resultado := app.agendar_lembretes_da_vespera(50);

  -- CASO 1: amanhã -> enfileirado.
  select r.status, r.skip_reason into v_status, v_motivo
    from app.appointment_reminders r where r.appointment_id = v_ap_amanha;
  if v_status is distinct from 'ENFILEIRADO' then
    raise exception 'S10/1: amanha esperava ENFILEIRADO, veio % (motivo %)', v_status, v_motivo;
  end if;

  -- CASO 2: hoje -> pulado, porque não existe véspera.
  select r.status, r.skip_reason into v_status, v_motivo
    from app.appointment_reminders r where r.appointment_id = v_ap_hoje;
  if v_status is distinct from 'PULADO' or v_motivo is distinct from 'AGENDADO_SEM_VESPERA' then
    raise exception 'S10/2: hoje esperava PULADO/AGENDADO_SEM_VESPERA, veio %/%', v_status, v_motivo;
  end if;

  -- CASO 3: daqui a três dias -> nenhuma linha ainda.
  select count(*) into v_quantas
    from app.appointment_reminders r where r.appointment_id = v_ap_longe;
  if v_quantas <> 0 then
    raise exception 'S10/3: tres dias nao podia ter decisao gravada, tem %', v_quantas;
  end if;

  -- ---------------------------------------------------------------------
  -- O QUE FOI PARAR NA FILA. É aqui que um insert errado apareceria.
  -- ---------------------------------------------------------------------
  select o.kind, o.template_name, o.template_language, o.template_params,
         o.recipient_address, o.status::text as st, o.idempotency_key
    into v_outbox
    from app.outbox_messages o
   where o.tenant_id = v_tenant;

  if v_outbox.kind is distinct from 'TEMPLATE' then
    raise exception 'S10: esperava kind TEMPLATE na fila, veio %', v_outbox.kind;
  end if;
  if v_outbox.template_name is distinct from 'lembrete_vespera' then
    raise exception 'S10: nome do modelo errado: %', v_outbox.template_name;
  end if;
  if v_outbox.template_language is distinct from 'pt_BR' then
    raise exception 'S10: idioma errado: %', v_outbox.template_language;
  end if;
  if jsonb_array_length(v_outbox.template_params) <> 4 then
    raise exception 'S10: esperava 4 parametros, veio %', jsonb_array_length(v_outbox.template_params);
  end if;
  -- Primeiro nome só, e a data tem que ser a de AMANHÃ -- não a de hoje.
  if (v_outbox.template_params ->> 0) is distinct from 'Rayana' then
    raise exception 'S10: primeiro parametro devia ser o primeiro nome, veio %',
      v_outbox.template_params ->> 0;
  end if;
  if (v_outbox.template_params ->> 1) is distinct from to_char(v_hoje + 1, 'DD/MM') then
    raise exception 'S10: a data do lembrete devia ser a de amanha (%), veio %',
      to_char(v_hoje + 1, 'DD/MM'), v_outbox.template_params ->> 1;
  end if;
  if v_outbox.recipient_address is distinct from '5500000001000' then
    raise exception 'S10: destinatario errado: %', v_outbox.recipient_address;
  end if;

  -- ---------------------------------------------------------------------
  -- IDEMPOTÊNCIA: o cron roda de 15 em 15 minutos e vai reencontrar tudo.
  -- Rodar de novo não pode produzir uma segunda mensagem.
  -- ---------------------------------------------------------------------
  v_resultado := app.agendar_lembretes_da_vespera(50);
  select count(*) into v_quantas from app.outbox_messages where tenant_id = v_tenant;
  if v_quantas <> 1 then
    raise exception 'S10: segunda rodada duplicou a fila, tem % mensagens', v_quantas;
  end if;

  raise notice 'S10 passou: fuso %, hoje %, lembrete para %', v_tz, v_hoje, v_hoje + 1;
end $$;

rollback;
