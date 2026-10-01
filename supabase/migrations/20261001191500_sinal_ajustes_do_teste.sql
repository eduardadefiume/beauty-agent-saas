-- O SINAL, AJUSTES DO TESTE (01/10): o que a matriz pegou.
-- 1. Dono responde "sim" de novo (ou "a Marina pagou" já confirmado): dizia
--    "não achei"; agora diz que já estava confirmado.
-- 2. "desmarcou com 1457h de antecedência": horas viram dias a partir de 48h.
-- 3. "disse que já pagou do sinal" -> "disse que já pagou o sinal".
-- 4. Prazo vencido: o teste de mecha marcado à parte (agendamento separado,
--    sem ligação com as luzes) continuava na agenda sem ninguém falar dele.
--    A mensagem de vencido agora avisa que ele continua marcado.

-- "20h", "2 dias", "61 dias"
create or replace function app.sinal_antecedencia(p_horas numeric)
returns text
language sql
immutable
set search_path to ''
as $$
  select case when p_horas is null then '?'
              when p_horas >= 48 then floor(p_horas / 24)::int || ' dias'
              else p_horas::int || 'h' end;
$$;
revoke all on function app.sinal_antecedencia(numeric) from public, anon, authenticated;

create or replace function app.sinal_comprovante_da_conversa(p_conversation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_conv app.crm_conversations%rowtype;
  v_a app.appointments%rowtype;
  v_d app.appointment_deposits%rowtype;
  v_c app.sinal_config%rowtype;
  v_m record;
  v_tz text;
  v_nome text;
  v_valor_lido integer;
  v_codigo text;
  v_aberto app.sinal_avisos%rowtype;
  v_texto_dono text;
  v_texto_cliente text;
  v_tipo text;
  v_r jsonb;
begin
  select * into v_conv from app.crm_conversations where id = p_conversation_id;
  if v_conv.id is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSA_NAO_EXISTE');
  end if;

  -- O horário com sinal esperando, ou o que venceu nos últimos 7 dias (pagou depois).
  select a.* into v_a
    from app.appointments a
    join app.appointment_deposits d on d.appointment_id = a.id
   where a.tenant_id = v_conv.tenant_id
     and right(regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
       = right(regexp_replace(coalesce(v_conv.external_conversation_ref, ''), '[^0-9]', '', 'g'), 11)
     and length(regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g')) >= 8
     and a.starts_at > statement_timestamp()
     and ((a.status = 'PENDING_SIGNAL' and d.status = 'PENDING')
          or (a.status = 'CANCELLED' and d.status = 'EXPIRED'
              and d.updated_at > statement_timestamp() - interval '7 days'))
   order by (a.status = 'PENDING_SIGNAL') desc, d.due_at
   limit 1;
  if v_a.id is null then
    return jsonb_build_object('ok', true, 'novo', false, 'reason', 'SEM_SINAL_ESPERANDO');
  end if;
  select * into v_d from app.appointment_deposits where appointment_id = v_a.id;
  select * into v_c from app.sinal_config where tenant_id = v_a.tenant_id;
  select coalesce(u.timezone, 'America/Sao_Paulo') into v_tz from app.units u where u.id = v_a.unit_id;
  v_nome := coalesce(nullif(split_part(trim(coalesce(v_a.customer_label, '')), ' ', 1), ''), 'A cliente');
  v_tipo := case when v_a.status = 'PENDING_SIGNAL' then 'COMPROVANTE' else 'PAGOU_DEPOIS' end;

  -- A última mensagem dela que parece pagamento, depois do cartão e ainda sem aviso.
  select m.id, m.body_text, m.media_understanding into v_m
    from app.crm_messages m
   where m.conversation_id = p_conversation_id
     and m.direction = 'INBOUND'
     and m.occurred_at >= v_d.created_at
     and app.sinal_parece_pagamento(m.body_text, m.media_understanding)
     and not exists (select 1 from app.sinal_avisos s where s.message_id = m.id)
   order by m.occurred_at desc
   limit 1;
  if v_m.id is null then
    return jsonb_build_object('ok', true, 'novo', false, 'reason', 'NADA_NOVO');
  end if;

  v_valor_lido := app.sinal_valor_lido(v_m.media_understanding);

  -- Já tem aviso aberto deste horário: este comprovante só se junta a ele.
  -- O dono recebe de novo só se agora veio um valor que antes não veio.
  select * into v_aberto from app.sinal_avisos
   where appointment_id = v_a.id and tipo in ('COMPROVANTE', 'PAGOU_DEPOIS') and status = 'ABERTO'
   order by created_at desc limit 1;

  v_codigo := coalesce(v_aberto.codigo, app.sinal_novo_codigo(v_a.tenant_id));

  insert into app.sinal_avisos (tenant_id, appointment_id, tipo, status, codigo, message_id, detalhe)
  values (v_a.tenant_id, v_a.id, v_tipo,
          case when v_aberto.id is null then 'ABERTO' else 'RESOLVIDO' end,
          case when v_aberto.id is null then v_codigo end,
          v_m.id,
          jsonb_build_object('valorLidoCentavos', v_valor_lido, 'foto', v_m.media_understanding is not null,
                             'juntoCom', v_aberto.id));

  if v_tipo = 'COMPROVANTE' then
    v_texto_dono :=
      '💰 *Comprovante de sinal* (#' || v_codigo || ')' || E'\n' ||
      v_nome || ' ' || case when v_m.media_understanding is not null then 'mandou o comprovante do sinal'
                            else 'disse que já pagou o sinal' end ||
      ' de *R$ ' || app.agenda_reais_curto(v_d.amount_cents) || '* — ' || app.sinal_o_que(v_a.id) || '.' ||
      case when v_valor_lido is not null and v_valor_lido <> v_d.amount_cents
             then E'\n' || '⚠️ No comprovante está *R$ ' || app.agenda_reais_curto(v_valor_lido)
                  || '*, e o sinal é R$ ' || app.agenda_reais_curto(v_d.amount_cents) || '.'
           when v_valor_lido is not null
             then E'\n' || 'No comprovante: R$ ' || app.agenda_reais_curto(v_valor_lido) || '.'
           when v_m.media_understanding is null
             then E'\n' || '(Ela não mandou foto do comprovante.)'
           else '' end ||
      E'\n\n' || 'Caiu na sua conta? Me responde *sim* ou *não*.';
    v_texto_cliente :=
      case when v_valor_lido is not null and v_valor_lido <> v_d.amount_cents
             then 'Recebi seu comprovante, obrigada! Só um detalhe: nele aparece R$ '
                  || app.agenda_reais_curto(v_valor_lido) || ' e o sinal é de R$ '
                  || app.agenda_reais_curto(v_d.amount_cents)
                  || '. Já passei pro salão conferir e te aviso assim que eles responderem.'
           when v_m.media_understanding is null
             then 'Obrigada! Já pedi pro salão conferir o Pix. Se puder, me manda o comprovante aqui que agiliza 💛'
           else 'Recebi seu comprovante, obrigada! 💛 Já passei pro salão conferir e te aviso assim que confirmarem.' end;
  else
    v_texto_dono :=
      '💰 *Pix depois do prazo* (#' || v_codigo || ')' || E'\n' ||
      v_nome || ' mandou o comprovante do sinal de *R$ ' || app.agenda_reais_curto(v_d.amount_cents) || '* — '
      || app.sinal_o_que(v_a.id) || '. Só que o prazo já tinha vencido e o horário foi liberado.' ||
      case when v_valor_lido is not null then E'\n' || 'No comprovante: R$ ' || app.agenda_reais_curto(v_valor_lido) || '.' else '' end ||
      E'\n\n' || 'Caiu na sua conta? Me responde *sim* ou *não*. Se caiu, aviso ela e ajudo a escolher um horário de novo.';
    v_texto_cliente :=
      'Recebi seu comprovante, obrigada! Como o prazo do sinal tinha vencido, aquele horário foi liberado. '
      || 'Já passei pro salão conferir o seu Pix e, assim que confirmarem, te ajudo a garantir um horário de novo 💛';
  end if;

  if v_aberto.id is null
     or (v_valor_lido is not null and coalesce((v_aberto.detalhe ->> 'valorLidoCentavos')::int, -1) <> v_valor_lido) then
    v_r := app.sinal_avisar_dono(v_a.tenant_id, v_texto_dono, 'sinal:comprovante:' || v_m.id::text, v_nome, v_codigo);
    if not coalesce((v_r ->> 'ok')::boolean, false) then
      update app.sinal_avisos set falhou = coalesce(v_r ->> 'reason', 'ERRO') where message_id = v_m.id;
    end if;
    if v_aberto.id is not null then
      update app.sinal_avisos set detalhe = detalhe || jsonb_build_object('valorLidoCentavos', v_valor_lido)
       where id = v_aberto.id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'novo', true, 'codigo', v_codigo, 'tipo', v_tipo,
    'textoParaCliente', v_texto_cliente, 'avisoAoDono', v_r);
end;
$$;

create or replace function app.sinal_dono_respondeu(p_tenant_id uuid, p_referencia text, p_pagou boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_ref text := translate(lower(trim(coalesce(p_referencia, ''))), 'áàâãéêíóôõúç#', 'aaaaeeiooouc');
  v_codigo text := upper((regexp_match(coalesce(p_referencia, ''), '[Ss]\s?(\d{4})'))[1]);
  v_alvos uuid[];
  v_a app.appointments%rowtype;
  v_d app.appointment_deposits%rowtype;
  v_c app.sinal_config%rowtype;
  v_tz text;
  v_conv uuid;
  v_nome text;
  v_ref_evento text;
  v_r jsonb;
  v_fin jsonb;
begin
  if v_codigo is not null then
    v_codigo := 'S' || v_codigo;
    select array_agg(distinct appointment_id) into v_alvos
      from app.sinal_avisos where tenant_id = p_tenant_id and codigo = v_codigo;
  else
    -- Quem está esperando o dono: aviso aberto primeiro; sem aviso, qualquer sinal pendente.
    with esperando as (
      select a.id, a.customer_label, 1 as prioridade
        from app.sinal_avisos s join app.appointments a on a.id = s.appointment_id
       where s.tenant_id = p_tenant_id and s.status = 'ABERTO' and s.tipo in ('COMPROVANTE', 'PAGOU_DEPOIS')
      union
      select a.id, a.customer_label, 2
        from app.appointments a join app.appointment_deposits d on d.appointment_id = a.id
       where a.tenant_id = p_tenant_id and a.status = 'PENDING_SIGNAL' and d.status = 'PENDING'
    ),
    casam as (
      select id, prioridade from esperando
       where v_ref = ''
          or translate(lower(coalesce(customer_label, '')), 'áàâãéêíóôõúç', 'aaaaeeiooouc')
             ~ ('\m' || regexp_replace(split_part(regexp_replace(v_ref, '^(a|o|da|do)\s+', ''), ' ', 1),
                                       '[^a-z0-9]', '', 'g') || '\M')
    )
    select array_agg(distinct id) into v_alvos from casam
     where prioridade = (select min(prioridade) from casam);
  end if;

  -- "sim" de novo, ou "a Marina pagou" depois de já confirmado: não é erro.
  if coalesce(array_length(v_alvos, 1), 0) = 0 and p_pagou then
    select array_agg(a.id) into v_alvos
      from app.appointments a
      join app.appointment_deposits d on d.appointment_id = a.id
     where a.tenant_id = p_tenant_id and a.status = 'CONFIRMED' and d.status = 'CONFIRMED'
       and d.confirmed_at > statement_timestamp() - interval '2 days'
       and (v_ref = '' or translate(lower(coalesce(a.customer_label, '')), 'áàâãéêíóôõúç', 'aaaaeeiooouc')
             ~ ('\m' || regexp_replace(split_part(regexp_replace(v_ref, '^(a|o|da|do)\s+', ''), ' ', 1),
                                       '[^a-z0-9]', '', 'g') || '\M'));
    if array_length(v_alvos, 1) = 1 then
      return jsonb_build_object('ok', true, 'confirmado', true, 'jaEstava', true,
        'texto', 'Esse já estava confirmado: ' || app.sinal_o_que(v_alvos[1]) || ' ('
                 || coalesce(nullif(split_part(trim(coalesce((select customer_label from app.appointments where id = v_alvos[1]), '')), ' ', 1), ''), 'cliente')
                 || ').');
    end if;
    v_alvos := null;
  end if;

  if coalesce(array_length(v_alvos, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'NAO_ACHEI',
      'texto', 'Não achei nenhum sinal esperando confirmação' ||
               case when v_ref <> '' then ' com "' || p_referencia || '"' else '' end || '.',
      'esperando', app.sinal_pendentes_do_dono(p_tenant_id));
  end if;
  if array_length(v_alvos, 1) > 1 then
    return jsonb_build_object('ok', false, 'reason', 'MAIS_DE_UM',
      'texto', 'Tem mais de um sinal esperando. Qual deles?',
      'esperando', app.sinal_pendentes_do_dono(p_tenant_id));
  end if;

  select * into v_a from app.appointments where id = v_alvos[1] for update;
  select * into v_d from app.appointment_deposits where appointment_id = v_a.id for update;
  select * into v_c from app.sinal_config where tenant_id = v_a.tenant_id;
  select coalesce(u.timezone, 'America/Sao_Paulo') into v_tz from app.units u where u.id = v_a.unit_id;
  v_conv := app.sinal_conversa_da_cliente(v_a.id);
  v_nome := coalesce(nullif(split_part(trim(coalesce(v_a.customer_label, '')), ' ', 1), ''), 'a cliente');

  if not p_pagou then
    update app.sinal_avisos set status = 'RESOLVIDO', resolvido_em = statement_timestamp(),
           detalhe = detalhe || '{"dono":"NAO_CAIU"}'
     where appointment_id = v_a.id and status = 'ABERTO' and tipo in ('COMPROVANTE', 'PAGOU_DEPOIS');
    v_r := app.sinal_mandar_para_cliente(v_a.tenant_id, v_conv,
      'Oi, ' || v_nome || '! O salão conferiu e o Pix de *R$ ' || app.agenda_reais_curto(v_d.amount_cents)
      || '* ainda não apareceu na conta 😕 Pode dar uma olhada se foi para a chave *'
      || coalesce(v_c.pix_chave, '(a do salão)') || '*' || coalesce(' (' || v_c.pix_titular || ')', '') || '?'
      || case when v_a.status = 'PENDING_SIGNAL'
              then ' Seu horário continua reservado até *' || app.sinal_quando(v_d.due_at, v_tz, statement_timestamp()) || '*.'
              else '' end,
      'sinal:nao-caiu:' || v_a.id::text || ':' || extract(epoch from statement_timestamp())::bigint::text);
    return jsonb_build_object('ok', true, 'confirmado', false,
      'texto', 'Certo, avisei a ' || v_nome || ' que o Pix não caiu' ||
               case when v_a.status = 'PENDING_SIGNAL'
                    then ' e que o horário fica reservado até ' || app.sinal_quando(v_d.due_at, v_tz, statement_timestamp())
                    else '' end || '.',
      'mensagemParaCliente', v_r);
  end if;

  -- Pagou.
  if v_a.status = 'CONFIRMED' then
    return jsonb_build_object('ok', true, 'confirmado', true, 'jaEstava', true,
      'texto', 'O horário da ' || v_nome || ' (' || app.sinal_o_que(v_a.id) || ') já estava confirmado.');
  end if;

  if v_a.status = 'PENDING_SIGNAL' and v_d.status = 'PENDING' then
    v_ref_evento := 'dono-whatsapp:' || v_d.id::text;
    insert into app.appointment_deposit_events (
      tenant_id, appointment_deposit_id, appointment_id, event_source,
      external_event_ref, resulting_status, correlation_id, actor_type, actor_id, metadata_minimized)
    values (v_a.tenant_id, v_d.id, v_a.id, 'MANUAL_VERIFIED', v_ref_evento, 'CONFIRMED',
            'sinal-dono-' || replace(gen_random_uuid()::text, '-', ''), 'USER', null,
            jsonb_build_object('canal', 'WHATSAPP_DO_DONO'))
    on conflict (tenant_id, event_source, external_event_ref) do nothing;
    update app.appointment_deposits set status = 'CONFIRMED', confirmed_at = statement_timestamp()
     where id = v_d.id and status = 'PENDING';
    update app.appointments set status = 'CONFIRMED', updated_at = statement_timestamp()
     where id = v_a.id and status = 'PENDING_SIGNAL';
    insert into app.audit_logs (tenant_id, actor_type, actor_id, action, entity_type, entity_id,
                                configuration_version_id, correlation_id, result, metadata_minimized)
    values (v_a.tenant_id, 'USER', null, 'APPOINTMENT_DEPOSIT_CONFIRMED', 'appointment_deposit', v_d.id,
            v_a.configuration_version_id, 'sinal-dono-' || left(v_d.id::text, 8), 'SUCCESS',
            jsonb_build_object('appointmentId', v_a.id, 'eventSource', 'MANUAL_VERIFIED', 'canal', 'WHATSAPP_DO_DONO'));
    update app.sinal_avisos set status = 'RESOLVIDO', resolvido_em = statement_timestamp(),
           detalhe = detalhe || '{"dono":"CAIU"}'
     where appointment_id = v_a.id and status = 'ABERTO' and tipo in ('COMPROVANTE', 'DONO_ESQUECEU');

    v_r := app.sinal_mandar_para_cliente(v_a.tenant_id, v_conv,
      '✅ *Sinal recebido!* Seu horário está confirmado: *' || app.sinal_o_que(v_a.id) || '*' ||
      coalesce(' com ' || (app.agenda_valores_do_agendamento(v_a.id) ->> 'profissional'), '') || '. 💛',
      'sinal:confirmado:' || v_a.id::text);
    if v_conv is not null then
      v_fin := app.enviar_finalizacao_do_agendamento(v_conv, v_a.id);
    end if;
    return jsonb_build_object('ok', true, 'confirmado', true,
      'texto', 'Confirmado ✅ ' || v_nome || ' — ' || app.sinal_o_que(v_a.id)
               || '. Já vai para a sua agenda do Google e mandei a confirmação pra ela.',
      'mensagemParaCliente', v_r, 'finalizacao', v_fin);
  end if;

  -- Pagou depois do prazo: o horário já foi liberado.
  update app.sinal_avisos set status = 'RESOLVIDO', resolvido_em = statement_timestamp(),
         detalhe = detalhe || jsonb_build_object('dono', 'CAIU', 'creditoCentavos', v_d.amount_cents)
   where appointment_id = v_a.id and status = 'ABERTO' and tipo = 'PAGOU_DEPOIS';
  v_r := app.sinal_mandar_para_cliente(v_a.tenant_id, v_conv,
    'Oi, ' || v_nome || '! O salão confirmou o seu Pix de *R$ ' || app.agenda_reais_curto(v_d.amount_cents)
    || '* 💛 Como o prazo tinha vencido, o horário de ' || app.sinal_o_que(v_a.id)
    || ' foi liberado. Me fala um dia que fica bom pra você que eu vejo os horários livres — o sinal que você pagou já vale pro novo horário.',
    'sinal:pagou-depois:' || v_a.id::text);
  return jsonb_build_object('ok', true, 'confirmado', false, 'pagouDepois', true,
    'texto', 'Anotado: a ' || v_nome || ' pagou R$ ' || app.agenda_reais_curto(v_d.amount_cents)
             || ' depois do prazo. Avisei ela para escolher outro horário; quando ela marcar, me fala "a '
             || v_nome || ' já pagou" que eu confirmo direto.',
    'mensagemParaCliente', v_r);
end;
$$;

create or replace function app.sinal_do_cancelamento(p_appointment_id uuid, p_agora timestamptz default null)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_a app.appointments%rowtype;
  v_d app.appointment_deposits%rowtype;
  v_c app.sinal_config%rowtype;
  v_horas numeric;
  v_devolve boolean;
begin
  select * into v_a from app.appointments where id = p_appointment_id;
  select * into v_d from app.appointment_deposits where appointment_id = p_appointment_id;
  if v_d.id is null or v_d.status <> 'CONFIRMED' then
    return jsonb_build_object('temSinalPago', false);
  end if;
  select * into v_c from app.sinal_config where tenant_id = v_a.tenant_id;
  v_horas := floor(extract(epoch from (v_a.starts_at - coalesce(p_agora, statement_timestamp()))) / 3600);
  v_devolve := coalesce(v_c.reembolso_respondido, false) and v_c.reembolso_ate_horas is not null
               and v_horas >= v_c.reembolso_ate_horas;
  return jsonb_build_object(
    'temSinalPago', true,
    'valor', 'R$ ' || app.agenda_reais_curto(v_d.amount_cents),
    'horasDeAntecedencia', v_horas,
    'regraHoras', v_c.reembolso_ate_horas,
    'regraRespondida', coalesce(v_c.reembolso_respondido, false),
    'devolve', v_devolve,
    'texto',
      case when not coalesce(v_c.reembolso_respondido, false)
             then 'Ela tinha pago sinal de R$ ' || app.agenda_reais_curto(v_d.amount_cents)
                  || '. O salão não definiu regra de devolução: diga que o salão vai falar com ela sobre o sinal. Não prometa devolver.'
           when v_devolve
             then 'Ela tinha pago sinal de R$ ' || app.agenda_reais_curto(v_d.amount_cents) || ' e avisou com '
                  || app.sinal_antecedencia(v_horas) || ' (a regra é ' || app.sinal_antecedencia(v_c.reembolso_ate_horas)
                  || '): o sinal VAI SER DEVOLVIDO pelo salão no Pix dela. Diga isso a ela e que o salão já foi avisado.'
           when v_c.reembolso_ate_horas is null
             then 'Ela tinha pago sinal de R$ ' || app.agenda_reais_curto(v_d.amount_cents)
                  || '. Pela regra do salão o sinal NÃO é devolvido quando desmarca. Diga com gentileza, sem culpar.'
           else 'Ela tinha pago sinal de R$ ' || app.agenda_reais_curto(v_d.amount_cents) || ' e avisou com '
                || app.sinal_antecedencia(v_horas) || ' (a regra é devolver só com ' || app.sinal_antecedencia(v_c.reembolso_ate_horas)
                || ' ou mais): o sinal NÃO é devolvido. Diga com gentileza, sem culpar, e ofereça remarcar.' end);
end;
$$;

create or replace function app.sinal_ao_cancelar()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v jsonb;
  v_nome text;
  v_tel text;
  v_r jsonb;
begin
  if new.status <> 'CANCELLED' or old.status is not distinct from 'CANCELLED' then
    return new;
  end if;
  -- Desmarcou antes de pagar: o sinal pendente deixa de existir.
  if old.status = 'PENDING_SIGNAL' then
    update app.appointment_deposits set status = 'CANCELLED'
     where appointment_id = new.id and status = 'PENDING';
    return new;
  end if;
  v := app.sinal_do_cancelamento(new.id);
  if not coalesce((v ->> 'temSinalPago')::boolean, false) then
    return new;
  end if;
  v_nome := coalesce(nullif(split_part(trim(coalesce(new.customer_label, '')), ' ', 1), ''), 'A cliente');
  v_tel := app.agenda_valores_do_agendamento(new.id) ->> 'telefone';
  if (v ->> 'devolve')::boolean then
    v_r := app.sinal_avisar_dono(new.tenant_id,
      '💸 *Devolver sinal* — ' || v_nome || ' desmarcou ' || app.sinal_o_que(new.id) || ' com '
      || app.sinal_antecedencia((v ->> 'horasDeAntecedencia')::numeric) || ' de antecedência. Pela sua regra (devolve com '
      || app.sinal_antecedencia((v ->> 'regraHoras')::numeric) || '), devolva *' || (v ->> 'valor') || '* no Pix dela' || coalesce(' (telefone ' || nullif(v_tel, '') || ')', '')
      || '. Confirme a chave Pix com ela antes.',
      'sinal:devolver:' || new.id::text, v_nome, null);
    insert into app.sinal_avisos (tenant_id, appointment_id, tipo, status, detalhe)
    values (new.tenant_id, new.id, 'DEVOLVER', 'ABERTO', v || jsonb_build_object('envio', v_r))
    on conflict do nothing;
  else
    v_r := app.sinal_avisar_dono(new.tenant_id,
      'ℹ️ ' || v_nome || ' desmarcou ' || app.sinal_o_que(new.id) || ' com '
      || app.sinal_antecedencia((v ->> 'horasDeAntecedencia')::numeric) || ' de antecedência. ' ||
      case when (v ->> 'regraRespondida')::boolean
           then 'Pela sua regra, o sinal de ' || (v ->> 'valor') || ' *não* é devolvido.'
           else 'Ela tinha pago ' || (v ->> 'valor') || ' de sinal e você ainda não me disse se devolve. Fale com ela.' end,
      'sinal:nao-devolve:' || new.id::text, v_nome, null);
    insert into app.sinal_avisos (tenant_id, appointment_id, tipo, status, detalhe)
    values (new.tenant_id, new.id, 'NAO_DEVOLVE', 'RESOLVIDO', v || jsonb_build_object('envio', v_r))
    on conflict do nothing;
  end if;
  return new;
end;
$$;

create or replace function app.sinal_rotina(p_agora timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_agora timestamptz := coalesce(p_agora, statement_timestamp());
  r record;
  v_tz text;
  v_c app.sinal_config%rowtype;
  v_conv uuid;
  v_nome text;
  v_r jsonb;
  v_hora int;
  v_lembretes int := 0;
  v_vencidos int := 0;
  v_avisos_vencido int := 0;
  v_dono int := 0;
  v_ok boolean;
  v_texto text;
begin
  -- 1. LEMBRETE: uma vez, se ela ainda não mandou comprovante.
  for r in
    select a.*, d.id as dep_id, d.amount_cents, d.due_at, d.created_at as dep_criado,
           coalesce(u.timezone, 'America/Sao_Paulo') as tz
      from app.appointment_deposits d
      join app.appointments a on a.id = d.appointment_id
      left join app.units u on u.id = a.unit_id
     where d.status = 'PENDING' and a.status = 'PENDING_SIGNAL'
       and d.due_at > v_agora
       and not exists (select 1 from app.sinal_avisos s where s.appointment_id = a.id
                        and (s.tipo = 'LEMBRETE' or (s.tipo = 'COMPROVANTE' and s.status = 'ABERTO')))
       and app.sinal_hora_do_lembrete(d.created_at, d.due_at, coalesce(u.timezone, 'America/Sao_Paulo')) <= v_agora
  loop
    v_hora := extract(hour from v_agora at time zone r.tz)::int;
    continue when v_hora < 8 or v_hora >= 21;
    select * into v_c from app.sinal_config where tenant_id = r.tenant_id;
    v_conv := app.sinal_conversa_da_cliente(r.id);
    v_nome := coalesce(nullif(split_part(trim(coalesce(r.customer_label, '')), ' ', 1), ''), '');
    v_texto :=
      'Oi' || case when v_nome <> '' then ', ' || v_nome else '' end || '! Passando pra lembrar 💛' || E'\n' ||
      'O sinal de *R$ ' || app.agenda_reais_curto(r.amount_cents) || '* do seu horário de *' || app.sinal_o_que(r.id)
      || '* vence *' || app.sinal_quando(r.due_at, r.tz, v_agora) || '*. Sem o sinal, o horário não fica garantido na agenda.'
      || E'\n\n' || 'Chave Pix: *' || coalesce(v_c.pix_chave, '(a do salão)') || '*'
      || coalesce(E'\n' || 'Nome: ' || v_c.pix_titular, '')
      || E'\n\n' || 'Já pagou? É só me mandar o comprovante aqui.';
    v_r := app.sinal_mandar_para_cliente(r.tenant_id, v_conv, v_texto, 'sinal:lembrete:' || r.id::text,
      'LEMBRETE_DO_SINAL',
      jsonb_build_array(coalesce(nullif(v_nome, ''), 'tudo bem'), app.agenda_reais_curto(r.amount_cents),
                        app.sinal_o_que(r.id), app.sinal_quando(r.due_at, r.tz, v_agora),
                        coalesce(v_c.pix_chave, '(a do salão)')));
    v_ok := coalesce((v_r ->> 'ok')::boolean, false);
    insert into app.sinal_avisos (tenant_id, appointment_id, tipo, status, falhou, detalhe, resolvido_em)
    values (r.tenant_id, r.id, 'LEMBRETE', case when v_ok then 'RESOLVIDO' else 'FALHOU' end,
            case when v_ok then null else coalesce(v_r ->> 'reason', 'ERRO') end,
            jsonb_build_object('envio', v_r), v_agora)
    on conflict do nothing;
    v_lembretes := v_lembretes + 1;
  end loop;

  -- 2. PRAZO VENCIDO.
  for r in
    select a.*, d.id as dep_id, d.amount_cents, d.due_at, coalesce(u.timezone, 'America/Sao_Paulo') as tz
      from app.appointment_deposits d
      join app.appointments a on a.id = d.appointment_id
      left join app.units u on u.id = a.unit_id
     where d.status = 'PENDING' and a.status = 'PENDING_SIGNAL' and d.due_at <= v_agora
     order by d.due_at
     for update of d skip locked
  loop
    v_nome := coalesce(nullif(split_part(trim(coalesce(r.customer_label, '')), ' ', 1), ''), 'A cliente');
    -- Ela mandou o comprovante antes do prazo e o dono não conferiu: o horário
    -- fica segurado. Liberar seria punir a cliente pela demora do salão.
    if exists (select 1 from app.sinal_avisos s where s.appointment_id = r.id and s.tipo = 'COMPROVANTE'
                and s.status = 'ABERTO' and s.created_at <= r.due_at) then
      if not exists (select 1 from app.sinal_avisos s where s.appointment_id = r.id and s.tipo = 'DONO_ESQUECEU') then
        v_r := app.sinal_avisar_dono(r.tenant_id,
          '⏰ O prazo do sinal da ' || v_nome || ' (' || app.sinal_o_que(r.id) || ') venceu agora, mas ela mandou o comprovante antes (#'
          || (select s.codigo from app.sinal_avisos s where s.appointment_id = r.id and s.tipo = 'COMPROVANTE'
                and s.status = 'ABERTO' and s.codigo is not null order by s.created_at limit 1)
          || '). O horário continua segurado até você me responder: o Pix de *R$ ' || app.agenda_reais_curto(r.amount_cents)
          || '* caiu? *sim* ou *não*.',
          'sinal:dono-esqueceu:' || r.id::text, v_nome, null);
        insert into app.sinal_avisos (tenant_id, appointment_id, tipo, status, detalhe)
        values (r.tenant_id, r.id, 'DONO_ESQUECEU', 'ABERTO', jsonb_build_object('envio', v_r))
        on conflict do nothing;
        v_dono := v_dono + 1;
      end if;
      continue;
    end if;

    insert into app.appointment_deposit_events (
      tenant_id, appointment_deposit_id, appointment_id, event_source,
      external_event_ref, resulting_status, correlation_id, actor_type, actor_id, metadata_minimized)
    values (r.tenant_id, r.dep_id, r.id, 'SYSTEM_EXPIRATION', r.dep_id::text || ':expired', 'EXPIRED',
            'sinal-rotina-' || left(r.dep_id::text, 8), 'WORKER', null, jsonb_build_object('reason', 'DUE_AT_ELAPSED'))
    on conflict (tenant_id, event_source, external_event_ref) do nothing;
    update app.appointment_deposits set status = 'EXPIRED' where id = r.dep_id and status = 'PENDING';
    update app.appointments set status = 'CANCELLED', updated_at = statement_timestamp()
     where id = r.id and status = 'PENDING_SIGNAL';
    update app.member_occupancies set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = r.tenant_id and source_type = 'APPOINTMENT' and source_id = r.id and status = 'ACTIVE';
    update app.resource_occupancies set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = r.tenant_id and source_type = 'APPOINTMENT' and source_id = r.id and status = 'ACTIVE';
    update app.strand_test_bookings set status = 'CANCELLED', updated_at = statement_timestamp()
     where tenant_id = r.tenant_id and main_appointment_id = r.id and status in ('SCHEDULED', 'COMPLETED');
    insert into app.audit_logs (tenant_id, actor_type, actor_id, action, entity_type, entity_id,
                                configuration_version_id, correlation_id, result, metadata_minimized)
    values (r.tenant_id, 'WORKER', null, 'APPOINTMENT_DEPOSIT_EXPIRED', 'appointment', r.id,
            r.configuration_version_id, 'sinal-rotina-' || left(r.id::text, 8), 'SUCCESS',
            jsonb_build_object('depositId', r.dep_id, 'reason', 'DUE_AT_ELAPSED'));
    -- O aviso à cliente sai no passo 3, na hora certa (não de madrugada).
    insert into app.sinal_avisos (tenant_id, appointment_id, tipo, status)
    values (r.tenant_id, r.id, 'VENCEU', 'ABERTO')
    on conflict do nothing;
    v_vencidos := v_vencidos + 1;
  end loop;

  -- 3. AVISO DE PRAZO VENCIDO, das 8h às 21h.
  for r in
    select s.id as aviso_id, a.*, d.amount_cents, coalesce(u.timezone, 'America/Sao_Paulo') as tz
      from app.sinal_avisos s
      join app.appointments a on a.id = s.appointment_id
      join app.appointment_deposits d on d.appointment_id = a.id
      left join app.units u on u.id = a.unit_id
     where s.tipo = 'VENCEU' and s.status = 'ABERTO'
  loop
    v_hora := extract(hour from v_agora at time zone r.tz)::int;
    continue when v_hora < 8 or v_hora >= 21;
    v_conv := app.sinal_conversa_da_cliente(r.id);
    v_nome := coalesce(nullif(split_part(trim(coalesce(r.customer_label, '')), ' ', 1), ''), '');
    v_texto :=
      'Oi' || case when v_nome <> '' then ', ' || v_nome else '' end || '! O prazo do sinal do seu horário de *'
      || app.sinal_o_que(r.id) || '* venceu e, como combinado, o horário foi liberado para outra cliente 😕'
      || E'\n\n' || 'Se ainda quiser fazer, me fala um dia que fica bom pra você que eu vejo os horários livres 💛'
      -- O teste de mecha marcado à parte continua na agenda: ela precisa saber.
      || coalesce(E'\n\n' || 'Seu teste de mecha de ' || (
           select app.sinal_quando(t.starts_at, r.tz)
             from app.appointments t
            where t.tenant_id = r.tenant_id and t.status = 'CONFIRMED' and t.starts_at > v_agora
              and t.starts_at < r.starts_at
              and right(regexp_replace(coalesce(t.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
                = right(regexp_replace(coalesce(r.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
              and translate(lower(coalesce(app.agenda_valores_do_agendamento(t.id) ->> 'servico', '')),
                            'áàâãéêíóôõúç', 'aaaaeeiooouc') ~ 'teste de mecha'
            order by t.starts_at limit 1)
         || ' continua marcado. Se não quiser mais, é só me avisar.', '');
    v_r := app.sinal_mandar_para_cliente(r.tenant_id, v_conv, v_texto, 'sinal:venceu:' || r.id::text,
      'SINAL_VENCEU', jsonb_build_array(coalesce(nullif(v_nome, ''), 'tudo bem'), app.sinal_o_que(r.id)));
    v_ok := coalesce((v_r ->> 'ok')::boolean, false);
    update app.sinal_avisos
       set status = case when v_ok then 'RESOLVIDO' else 'FALHOU' end,
           falhou = case when v_ok then null else coalesce(v_r ->> 'reason', 'ERRO') end,
           detalhe = detalhe || jsonb_build_object('envio', v_r), resolvido_em = v_agora
     where id = r.aviso_id;
    v_avisos_vencido := v_avisos_vencido + 1;
  end loop;

  return jsonb_build_object('lembretes', v_lembretes, 'vencidos', v_vencidos,
                            'avisosDeVencido', v_avisos_vencido, 'donoCobrado', v_dono);
end;
$$;
