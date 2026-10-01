-- O DONO NÃO PRECISA MAIS LEMBRAR DO CRÉDITO.
-- 01/10, ao vivo: depois do crédito automático (20261001210000), o Eddy
-- ainda dizia ao William "quando ela marcar, me fala 'a Luana já pagou'".
-- Agora diz o que acontece de verdade.

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
             || ' depois do prazo. Ficou como crédito dela: quando ela marcar de novo, o horário já sai confirmado. '
             || 'Se em 7 dias ela não achar horário, eu te aviso para devolver.',
    'mensagemParaCliente', v_r);
end;
$$;
