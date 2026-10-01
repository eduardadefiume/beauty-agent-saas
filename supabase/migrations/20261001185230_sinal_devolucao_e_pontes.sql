-- O sinal, parte 3 de 3 (a parte 1 explica o pedido da Duda).

-- DESMARCOU DEPOIS DE PAGAR: a regra do dono decide; o dono fica sabendo.
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
                  || v_horas || 'h (a regra é ' || v_c.reembolso_ate_horas
                  || 'h): o sinal VAI SER DEVOLVIDO pelo salão no Pix dela. Diga isso a ela e que o salão já foi avisado.'
           when v_c.reembolso_ate_horas is null
             then 'Ela tinha pago sinal de R$ ' || app.agenda_reais_curto(v_d.amount_cents)
                  || '. Pela regra do salão o sinal NÃO é devolvido quando desmarca. Diga com gentileza, sem culpar.'
           else 'Ela tinha pago sinal de R$ ' || app.agenda_reais_curto(v_d.amount_cents) || ' e avisou com '
                || v_horas || 'h (a regra é devolver só com ' || v_c.reembolso_ate_horas
                || 'h ou mais): o sinal NÃO é devolvido. Diga com gentileza, sem culpar, e ofereça remarcar.' end);
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
      || (v ->> 'horasDeAntecedencia') || 'h de antecedência. Pela sua regra (devolve com ' || (v ->> 'regraHoras')
      || 'h), devolva *' || (v ->> 'valor') || '* no Pix dela' || coalesce(' (telefone ' || nullif(v_tel, '') || ')', '')
      || '. Confirme a chave Pix com ela antes.',
      'sinal:devolver:' || new.id::text, v_nome, null);
    insert into app.sinal_avisos (tenant_id, appointment_id, tipo, status, detalhe)
    values (new.tenant_id, new.id, 'DEVOLVER', 'ABERTO', v || jsonb_build_object('envio', v_r))
    on conflict do nothing;
  else
    v_r := app.sinal_avisar_dono(new.tenant_id,
      'ℹ️ ' || v_nome || ' desmarcou ' || app.sinal_o_que(new.id) || ' com ' || (v ->> 'horasDeAntecedencia')
      || 'h de antecedência. ' ||
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

-- Sem DROP TRIGGER: ele pede trava exclusiva na appointments e, no DEV, fica
-- esperando os workers. CREATE TRIGGER usa uma trava mais leve.
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'sinal_ao_cancelar'
                   and tgrelid = 'app.appointments'::regclass) then
    create trigger sinal_ao_cancelar
      after update of status on app.appointments
      for each row when (new.status = 'CANCELLED' and old.status is distinct from 'CANCELLED')
      execute function app.sinal_ao_cancelar();
  end if;
end $$;

-- Pontes para as edge functions (PostgREST só enxerga o public).
create or replace function public.sinal_comprovante_da_conversa(p_conversation_id uuid)
returns jsonb language sql security definer set search_path to ''
as $$ select app.sinal_comprovante_da_conversa(p_conversation_id); $$;
create or replace function public.sinal_dono_respondeu(p_tenant_id uuid, p_referencia text, p_pagou boolean)
returns jsonb language sql security definer set search_path to ''
as $$ select app.sinal_dono_respondeu(p_tenant_id, p_referencia, p_pagou); $$;
create or replace function public.sinal_pendentes_do_dono(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.sinal_pendentes_do_dono(p_tenant_id); $$;
create or replace function public.sinal_do_cancelamento(p_appointment_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.sinal_do_cancelamento(p_appointment_id, null); $$;

do $$
declare f text;
begin
  foreach f in array array[
    'app.sinal_quando(timestamptz,text,timestamptz)', 'app.sinal_o_que(uuid)',
    'app.sinal_conversa_da_cliente(uuid)', 'app.sinal_mandar_para_cliente(uuid,uuid,text,text,text,jsonb)',
    'app.sinal_avisar_dono(uuid,text,text,text,text)', 'app.sinal_parece_pagamento(text,text)',
    'app.sinal_valor_lido(text)', 'app.sinal_novo_codigo(uuid)', 'app.sinal_comprovante_da_conversa(uuid)',
    'app.sinal_dono_respondeu(uuid,text,boolean)', 'app.sinal_pendentes_do_dono(uuid)',
    'app.sinal_hora_do_lembrete(timestamptz,timestamptz,text)', 'app.sinal_rotina(timestamptz)',
    'app.sinal_do_cancelamento(uuid,timestamptz)', 'app.sinal_ao_cancelar()',
    'public.sinal_comprovante_da_conversa(uuid)', 'public.sinal_dono_respondeu(uuid,text,boolean)',
    'public.sinal_pendentes_do_dono(uuid)', 'public.sinal_do_cancelamento(uuid)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.sinal_comprovante_da_conversa(uuid)', 'public.sinal_dono_respondeu(uuid,text,boolean)',
    'public.sinal_pendentes_do_dono(uuid)', 'public.sinal_do_cancelamento(uuid)']
  loop
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
