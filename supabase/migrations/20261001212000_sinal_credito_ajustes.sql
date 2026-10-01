-- CRÉDITO DO SINAL, AJUSTES DO TESTE (01/10):
-- 1. Sobra do crédito: o dono lia "usou o sinal de R$ 100" quando o sinal novo
--    era R$ 50 e sobravam R$ 50. Agora diz quanto saiu e quanto sobrou.
-- 2. Telefone na devolução saía "99900003120"; agora "99-90000-3120".

create or replace function app.sinal_credito_usa()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_a app.appointments%rowtype;
  v_cr app.sinal_creditos%rowtype;
  v_nome text;
begin
  if new.status not in ('PENDING', 'NOT_REQUIRED') then
    return new;
  end if;
  select * into v_a from app.appointments where id = new.appointment_id;
  select * into v_cr from app.sinal_creditos
   where tenant_id = v_a.tenant_id and status = 'DISPONIVEL'
     and contato_digitos = app.sinal_digitos(v_a.external_contact_ref)
     and length(contato_digitos) >= 8
   order by criado_em limit 1 for update;
  if v_cr.id is null then
    return new;
  end if;
  v_nome := coalesce(v_cr.cliente_nome, nullif(split_part(trim(coalesce(v_a.customer_label, '')), ' ', 1), ''), 'A cliente');

  if new.status = 'PENDING' and v_cr.valor_centavos >= new.amount_cents then
    insert into app.appointment_deposit_events (
      tenant_id, appointment_deposit_id, appointment_id, event_source,
      external_event_ref, resulting_status, correlation_id, actor_type, actor_id, metadata_minimized)
    values (v_a.tenant_id, new.id, v_a.id, 'MANUAL_VERIFIED', 'credito:' || v_cr.id::text, 'CONFIRMED',
            'sinal-credito-' || left(v_cr.id::text, 8), 'SYSTEM', null,
            jsonb_build_object('creditoId', v_cr.id, 'origem', v_cr.origem_appointment_id))
    on conflict (tenant_id, event_source, external_event_ref) do nothing;
    update app.appointment_deposits set status = 'CONFIRMED', confirmed_at = statement_timestamp()
     where id = new.id and status = 'PENDING';
    update app.appointments set status = 'CONFIRMED', updated_at = statement_timestamp()
     where id = v_a.id and status = 'PENDING_SIGNAL';
    update app.sinal_creditos set status = 'USADO', usado_em_appointment_id = v_a.id,
           resolvido_em = statement_timestamp()
     where id = v_cr.id;
    if v_cr.valor_centavos > new.amount_cents then
      insert into app.sinal_creditos (tenant_id, contato_digitos, cliente_nome, valor_centavos, vence_em, motivo)
      values (v_cr.tenant_id, v_cr.contato_digitos, v_cr.cliente_nome,
              v_cr.valor_centavos - new.amount_cents, v_cr.vence_em, 'sobra do crédito ' || v_cr.id::text);
    end if;
    perform app.sinal_avisar_dono(v_a.tenant_id,
      '💳 ' || v_nome || ' marcou de novo e o sinal de *R$ ' || app.agenda_reais_curto(new.amount_cents)
      || '* saiu do que ela tinha pago depois do prazo: ' || app.sinal_o_que(v_a.id) || '. Já está confirmado.'
      || case when v_cr.valor_centavos > new.amount_cents
              then ' Sobrou R$ ' || app.agenda_reais_curto(v_cr.valor_centavos - new.amount_cents) || ' de crédito para ela.'
              else '' end,
      'sinal:credito-usado:' || v_cr.id::text, v_nome, null);
  elsif new.status = 'PENDING' then
    perform app.sinal_avisar_dono(v_a.tenant_id,
      'ℹ️ ' || v_nome || ' tem crédito de R$ ' || app.agenda_reais_curto(v_cr.valor_centavos)
      || ' (sinal pago depois do prazo), mas o sinal do novo horário (' || app.sinal_o_que(v_a.id) || ') é R$ '
      || app.agenda_reais_curto(new.amount_cents) || '. Ela recebeu o cartão normal; se quiser abater, me fala "a '
      || v_nome || ' já pagou".',
      'sinal:credito-menor:' || v_cr.id::text || ':' || new.id::text, v_nome, null);
  else
    update app.sinal_creditos set status = 'ABATIDO_NO_DIA', usado_em_appointment_id = v_a.id,
           resolvido_em = statement_timestamp()
     where id = v_cr.id;
    perform app.sinal_avisar_dono(v_a.tenant_id,
      '💳 ' || v_nome || ' marcou ' || app.sinal_o_que(v_a.id) || ' e tem *R$ '
      || app.agenda_reais_curto(v_cr.valor_centavos)
      || '* de sinal pago depois do prazo. Esse serviço não pede sinal: abata esse valor no dia.',
      'sinal:credito-abatido:' || v_cr.id::text, v_nome, null);
  end if;
  return new;
end;
$$;

create or replace function app.sinal_devolver_credito(p_credito_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_cr app.sinal_creditos%rowtype;
  v_conv uuid;
  v_r jsonb;
begin
  update app.sinal_creditos set status = 'DEVOLVER', motivo = p_motivo, resolvido_em = statement_timestamp()
   where id = p_credito_id and status = 'DISPONIVEL'
  returning * into v_cr;
  if v_cr.id is null then
    return jsonb_build_object('ok', false, 'reason', 'CREDITO_NAO_DISPONIVEL');
  end if;
  v_r := app.sinal_avisar_dono(v_cr.tenant_id,
    '💸 *Devolver sinal* — ' || coalesce(v_cr.cliente_nome, 'A cliente') || ' tem *R$ '
    || app.agenda_reais_curto(v_cr.valor_centavos) || '* de sinal pago depois do prazo e '
    || p_motivo || '. Devolva no Pix dela (telefone ' || coalesce(app.telefone_legivel(v_cr.contato_digitos), v_cr.contato_digitos) || '). Confirme a chave Pix com ela antes.',
    'sinal:credito-devolver:' || v_cr.id::text, v_cr.cliente_nome, null);
  return jsonb_build_object('ok', true, 'valor', 'R$ ' || app.agenda_reais_curto(v_cr.valor_centavos),
    'texto', 'O salão vai devolver o sinal de R$ ' || app.agenda_reais_curto(v_cr.valor_centavos)
             || ' no Pix dela; o dono já foi avisado.',
    'avisoAoDono', v_r);
end;
$$;
