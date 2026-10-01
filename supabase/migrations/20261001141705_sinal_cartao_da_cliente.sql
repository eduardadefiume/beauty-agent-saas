-- SINAL PASSO 4: O CARTÃO QUE A CLIENTE RECEBE.
--
-- Montado pelo banco, nunca pelo modelo: valor, prazo e chave Pix não podem
-- sair errados. Sai logo depois da mensagem da atendente, quando a reserva
-- nasce PENDING_SIGNAL. A finalização do dono só sai depois do pagamento.
create or replace function app.sinal_cartao(p_appointment_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  a app.appointments%rowtype;
  d app.appointment_deposits%rowtype;
  c app.sinal_config%rowtype;
  v jsonb;
  v_tz text;
  v_ini timestamp;
  v_prazo timestamp;
  v_dias text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_texto text;
begin
  select * into a from app.appointments where id = p_appointment_id;
  select * into d from app.appointment_deposits where appointment_id = p_appointment_id;
  if a.id is null or d.id is null or d.status <> 'PENDING' or a.status <> 'PENDING_SIGNAL' then
    return jsonb_build_object('comSinal', false);
  end if;
  select * into c from app.sinal_config where tenant_id = a.tenant_id;
  v := app.agenda_valores_do_agendamento(a.id);
  select coalesce(u.timezone, 'America/Sao_Paulo') into v_tz from app.units u where u.id = a.unit_id;
  v_tz := coalesce(v_tz, 'America/Sao_Paulo');
  v_ini := a.starts_at at time zone v_tz;
  v_prazo := d.due_at at time zone v_tz;

  v_texto :=
    '📌 *Seu horário está reservado!*' || E'\n' ||
    (v ->> 'servico') || ' — ' || v_dias[extract(dow from v_ini)::int + 1] || ', ' ||
      to_char(v_ini, 'DD/MM') || ' às ' || to_char(v_ini, 'HH24"h"MI') ||
      coalesce(', com ' || (v ->> 'profissional'), '') || E'\n' ||
    case when v ->> 'valorCentavos' is not null
         then 'Valor: R$ ' || app.agenda_reais_curto((v ->> 'valorCentavos')::int) || ' | '
         else '' end ||
    'Sinal: *R$ ' || app.agenda_reais_curto(d.amount_cents) || '*' ||
    case when v ->> 'valorCentavos' is not null then ' (já descontado do valor)' else '' end || E'\n\n' ||
    'Para confirmar, faça o Pix do sinal até *' || v_dias[extract(dow from v_prazo)::int + 1] || ', ' ||
      to_char(v_prazo, 'DD/MM') || ' às ' || to_char(v_prazo, 'HH24"h"MI') || '*:' || E'\n' ||
    'Chave Pix: ' || coalesce(c.pix_chave, '(o salão te passa)') || E'\n' ||
    coalesce('Nome: ' || c.pix_titular || E'\n', '') ||
    'Depois é só me mandar o comprovante aqui. 💛' || E'\n\n' ||
    'O sinal garante o seu horário. Se não for pago até o prazo, ele é liberado para outra cliente.' ||
    case when c.reembolso_respondido and c.reembolso_ate_horas is not null
           then ' Se precisar desmarcar com pelo menos ' || c.reembolso_ate_horas || 'h de antecedência, o sinal é devolvido.'
         when c.reembolso_respondido
           then ' Se precisar desmarcar, o sinal não é devolvido.'
         else '' end;

  return jsonb_build_object('comSinal', true, 'texto', v_texto,
    'valorCentavos', d.amount_cents, 'prazo', d.due_at);
end;
$function$;

-- Envia o cartão na conversa dela (uma vez por agendamento).
create or replace function app.enviar_cartao_do_sinal(p_conversation_id uuid, p_appointment_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v jsonb;
  v_tenant uuid;
begin
  v := app.sinal_cartao(p_appointment_id);
  if not coalesce((v ->> 'comSinal')::boolean, false) then
    return jsonb_build_object('ok', true, 'enviado', false);
  end if;
  select tenant_id into v_tenant from app.appointments where id = p_appointment_id;
  return jsonb_build_object('ok', true, 'enviado', true,
    'fila', app.enqueue_outbound_message(v_tenant, p_conversation_id, v ->> 'texto', 'AGENT',
              'sinal:cartao:' || p_appointment_id::text, null, null, null, null));
end;
$function$;

revoke all on function app.sinal_cartao(uuid) from public, anon, authenticated;
revoke all on function app.enviar_cartao_do_sinal(uuid, uuid) from public, anon, authenticated;

create or replace function public.enviar_cartao_do_sinal(p_conversation_id uuid, p_appointment_id uuid)
 returns jsonb language sql security definer set search_path to ''
as $function$ select app.enviar_cartao_do_sinal(p_conversation_id, p_appointment_id); $function$;
revoke all on function public.enviar_cartao_do_sinal(uuid, uuid) from public, anon, authenticated;
grant execute on function public.enviar_cartao_do_sinal(uuid, uuid) to service_role;

notify pgrst, 'reload schema';