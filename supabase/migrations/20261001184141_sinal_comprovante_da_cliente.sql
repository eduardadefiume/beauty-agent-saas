-- O SINAL DEPOIS DO CARTÃO: comprovante, dono confirma, lembrete, prazo vencido, devolução.
--
-- Pedido da Duda (01/10): a cliente manda o comprovante, o Eddy pergunta ao
-- dono "a Marina pagou R$ 100?", ele responde "sim" e o horário é confirmado
-- (vai para o Google, a finalização sai). Lembrete antes do prazo. Prazo
-- vencido: o horário é liberado e a cliente é avisada com educação. Desmarcou
-- depois de pagar: devolve ou não pela regra do dono, e o Eddy avisa o dono
-- quando ele tem que devolver.
--
-- Tudo aqui é determinístico: o modelo só repete o texto que estas funções
-- devolvem. Dinheiro e agenda não dependem de interpretação.

create table if not exists app.sinal_avisos (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id),
  appointment_id uuid not null references app.appointments(id),
  tipo text not null check (tipo in
    ('COMPROVANTE', 'LEMBRETE', 'VENCEU', 'PAGOU_DEPOIS', 'DEVOLVER', 'NAO_DEVOLVE', 'DONO_ESQUECEU')),
  status text not null default 'ABERTO' check (status in ('ABERTO', 'RESOLVIDO', 'FALHOU')),
  codigo text,
  message_id uuid,
  detalhe jsonb not null default '{}'::jsonb,
  falhou text,
  created_at timestamptz not null default statement_timestamp(),
  resolvido_em timestamptz
);
create unique index if not exists sinal_avisos_uma_vez
  on app.sinal_avisos (appointment_id, tipo)
  where tipo in ('LEMBRETE', 'VENCEU', 'DEVOLVER', 'NAO_DEVOLVE', 'DONO_ESQUECEU');
create unique index if not exists sinal_avisos_por_mensagem
  on app.sinal_avisos (message_id) where message_id is not null;
create index if not exists sinal_avisos_abertos
  on app.sinal_avisos (tenant_id, status, tipo);
alter table app.sinal_avisos enable row level security;
revoke all on app.sinal_avisos from public, anon, authenticated;

-- "hoje às 13h14", "amanhã às 9h", "segunda 01/12 às 9h". Sem p_agora: sempre o dia da semana.
create or replace function app.sinal_quando(p_ts timestamptz, p_tz text, p_agora timestamptz default null)
returns text
language plpgsql
stable
set search_path to ''
as $$
declare
  v_l timestamp := p_ts at time zone coalesce(p_tz, 'America/Sao_Paulo');
  v_hoje date := (coalesce(p_agora, p_ts - interval '30 days') at time zone coalesce(p_tz, 'America/Sao_Paulo'))::date;
  v_dias text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_hora text := replace(to_char(v_l, 'FMHH24"h"MI'), 'h00', 'h');
begin
  return case v_l::date - v_hoje
           when 0 then 'hoje'
           when 1 then 'amanhã'
           else v_dias[extract(dow from v_l)::int + 1] || ' ' || to_char(v_l, 'DD/MM') end
         || ' às ' || v_hora;
end;
$$;

-- "Luzes, segunda 01/12 às 9h"
create or replace function app.sinal_o_que(p_appointment_id uuid)
returns text
language sql
stable security definer
set search_path to ''
as $$
  select (app.agenda_valores_do_agendamento(a.id) ->> 'servico') || ', '
         || app.sinal_quando(a.starts_at, coalesce(u.timezone, 'America/Sao_Paulo'))
    from app.appointments a left join app.units u on u.id = a.unit_id
   where a.id = p_appointment_id;
$$;

create or replace function app.sinal_conversa_da_cliente(p_appointment_id uuid)
returns uuid
language sql
stable security definer
set search_path to ''
as $$
  select c.id
    from app.appointments a
    join app.crm_conversations c
      on c.tenant_id = a.tenant_id
     and right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 11)
       = right(regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
   where a.id = p_appointment_id
     and length(regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g')) >= 8
     and not exists (select 1 from app.owner_whatsapp o
                      where o.tenant_id = a.tenant_id and o.status = 'ACTIVE'
                        and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8)
                          = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 8))
   order by c.last_inbound_at desc nulls last
   limit 1;
$$;

-- Mensagem à cliente. Janela de 24h fechada: modelo aprovado, se o salão tiver.
create or replace function app.sinal_mandar_para_cliente(
  p_tenant_id uuid, p_conversation_id uuid, p_texto text, p_chave text,
  p_modelo text default null, p_params jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_r jsonb;
begin
  if p_conversation_id is null then
    return jsonb_build_object('ok', false, 'reason', 'CLIENTE_SEM_CONVERSA');
  end if;
  v_r := app.enqueue_outbound_message(p_tenant_id, p_conversation_id, p_texto, 'SYSTEM'::app.outbound_actor,
                                      p_chave, null, null, null, null);
  if coalesce(v_r ->> 'reason', '') = 'SERVICE_WINDOW_CLOSED' and p_modelo is not null then
    v_r := app.enqueue_outbound_template(p_tenant_id, p_conversation_id, p_modelo, p_params,
                                         p_chave || ':modelo', p_texto);
  end if;
  return v_r;
end;
$$;

-- Mensagem ao dono, na conversa do Eddy. Mesmo caminho de avisar_dono_da_pergunta.
create or replace function app.sinal_avisar_dono(p_tenant_id uuid, p_texto text, p_chave text,
                                                 p_cliente text, p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_conversa uuid;
  v_r jsonb;
begin
  select c.id into v_conversa
    from app.crm_conversations c
    join app.owner_whatsapp o
      on o.tenant_id = c.tenant_id and o.status = 'ACTIVE'
     and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8)
         = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 8)
   where c.tenant_id = p_tenant_id
   order by c.last_inbound_at desc nulls last
   limit 1;
  if v_conversa is null then
    return jsonb_build_object('ok', false, 'reason', 'DONO_SEM_CONVERSA');
  end if;
  v_r := app.enqueue_outbound_message(p_tenant_id, v_conversa, p_texto, 'SYSTEM'::app.outbound_actor,
                                      p_chave, null, null, null, null);
  if coalesce(v_r ->> 'reason', '') = 'SERVICE_WINDOW_CLOSED' then
    v_r := app.enqueue_outbound_template(
      p_tenant_id, v_conversa, 'AVISO_AO_DONO',
      jsonb_build_array(
        (select t.display_name from app.tenants t where t.id = p_tenant_id),
        coalesce(p_cliente, '?'),
        left(regexp_replace(p_texto, '\s+', ' ', 'g'), 700),
        '#' || coalesce(p_codigo, '?')),
      p_chave || ':modelo', p_texto);
  end if;
  return v_r;
end;
$$;

-- Comprovante na foto ou "paguei" no texto. Na dúvida, não é comprovante:
-- uma foto do cabelo tratada como pagamento seria pior que esperar o dono.
create or replace function app.sinal_parece_pagamento(p_texto text, p_leitura text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select
    coalesce(translate(lower(p_leitura), 'áàâãéêíóôõúç', 'aaaaeeiooouc'), '')
      ~ '(comprovante|pix (enviado|realizado|efetuado)|transferencia (realizada|enviada|efetuada)|id da transacao|autenticacao|e2e|chave pix)'
    or coalesce(translate(lower(p_texto), 'áàâãéêíóôõúç', 'aaaaeeiooouc'), '')
      ~ '(\mpaguei\M|\mja paguei\M|fiz o pix|fiz pix|mandei o pix|enviei o pix|pix feito|pix enviado|ta pago|esta pago|transferi|segue o comprovante|\mcomprovante\M|ja fiz o pagamento|pagamento feito|pagamento realizado|acabei de pagar)'
    and coalesce(translate(lower(p_texto), 'áàâãéêíóôõúç', 'aaaaeeiooouc'), '')
      !~ '(\mnao paguei|ainda nao (fiz|paguei|mandei)|vou pagar|vou fazer o pix|posso pagar|como (eu )?pago|onde (eu )?pago|qual (e )?a chave)';
$$;

-- "R$ 100,00" lido do comprovante, em centavos. Null se não achar.
create or replace function app.sinal_valor_lido(p_leitura text)
returns integer
language sql
immutable
set search_path to ''
as $$
  select (replace(replace(m[1], '.', ''), ',', '')::integer)
    from regexp_match(coalesce(p_leitura, ''), 'R\$\s*([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2})') m;
$$;

create or replace function app.sinal_novo_codigo(p_tenant_id uuid)
returns text
language plpgsql
volatile
set search_path to ''
as $$
declare
  v text;
begin
  loop
    v := 'S' || (1000 + floor(random() * 9000))::int::text;
    exit when not exists (select 1 from app.sinal_avisos where tenant_id = p_tenant_id and codigo = v);
  end loop;
  return v;
end;
$$;

-- A CLIENTE MANDOU O COMPROVANTE (ou disse que pagou).
-- Chamada pela atendente a cada turno: olha as mensagens dela desde o cartão
-- que ainda não viraram aviso. Devolve o texto que a atendente tem que dizer.
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
      v_nome || ' ' || case when v_m.media_understanding is not null then 'mandou o comprovante'
                            else 'disse que já pagou' end ||
      ' do sinal de *R$ ' || app.agenda_reais_curto(v_d.amount_cents) || '* — ' || app.sinal_o_que(v_a.id) || '.' ||
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
