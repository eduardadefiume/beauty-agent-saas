-- CRÉDITO DO SINAL PAGO DEPOIS DO PRAZO.
--
-- Pedido da Duda (01/10): a cliente pagou o sinal depois que o prazo venceu e
-- o horário já tinha sido liberado. O dono confirma que o Pix caiu. O certo:
-- o valor fica como CRÉDITO dela e, quando ela marcar de novo, o horário
-- confirma sozinho; se não houver horário que sirva para ela (ou ela pedir o
-- dinheiro), o salão devolve. Até aqui o dono tinha que lembrar de dizer "a
-- Marina já pagou" e a cliente recebia um segundo cartão de sinal.
--
-- Regras:
--   * crédito nasce quando o dono diz que o Pix depois do prazo caiu;
--   * nova reserva COM sinal: crédito >= sinal -> sinal pago, horário
--     confirmado (sobra vira crédito novo); crédito menor -> não usa, avisa o dono;
--   * nova reserva SEM sinal: crédito abatido no dia, o dono é avisado;
--   * sem horário que sirva / ela pede o dinheiro: devolução (atendente);
--   * 7 dias sem marcar: devolução automática, dono e cliente avisados.

create table if not exists app.sinal_creditos (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references app.tenants(id),
  contato_digitos text not null,
  cliente_nome text,
  valor_centavos integer not null check (valor_centavos > 0),
  origem_appointment_id uuid references app.appointments(id),
  status text not null default 'DISPONIVEL'
    check (status in ('DISPONIVEL', 'USADO', 'ABATIDO_NO_DIA', 'DEVOLVER')),
  usado_em_appointment_id uuid references app.appointments(id),
  vence_em timestamptz not null default statement_timestamp() + interval '7 days',
  motivo text,
  criado_em timestamptz not null default statement_timestamp(),
  resolvido_em timestamptz
);
create index if not exists sinal_creditos_da_cliente
  on app.sinal_creditos (tenant_id, contato_digitos) where status = 'DISPONIVEL';
create unique index if not exists sinal_creditos_uma_origem
  on app.sinal_creditos (origem_appointment_id) where origem_appointment_id is not null;
alter table app.sinal_creditos enable row level security;
revoke all on app.sinal_creditos from public, anon, authenticated;

create or replace function app.sinal_digitos(p_ref text)
returns text language sql immutable set search_path to ''
as $$ select right(regexp_replace(coalesce(p_ref, ''), '[^0-9]', '', 'g'), 11); $$;
revoke all on function app.sinal_digitos(text) from public, anon, authenticated;

-- 1. O dono disse que o Pix depois do prazo caiu: nasce o crédito.
create or replace function app.sinal_credito_nasce()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_a app.appointments%rowtype;
begin
  if new.tipo <> 'PAGOU_DEPOIS' or old.status <> 'ABERTO' or new.status <> 'RESOLVIDO'
     or coalesce(new.detalhe ->> 'dono', '') <> 'CAIU' then
    return new;
  end if;
  select * into v_a from app.appointments where id = new.appointment_id;
  if length(app.sinal_digitos(v_a.external_contact_ref)) < 8 then
    return new;
  end if;
  insert into app.sinal_creditos (tenant_id, contato_digitos, cliente_nome, valor_centavos, origem_appointment_id)
  select v_a.tenant_id, app.sinal_digitos(v_a.external_contact_ref),
         nullif(split_part(trim(coalesce(v_a.customer_label, '')), ' ', 1), ''),
         d.amount_cents, v_a.id
    from app.appointment_deposits d where d.appointment_id = v_a.id and d.amount_cents > 0
  on conflict do nothing;
  return new;
end;
$$;
revoke all on function app.sinal_credito_nasce() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'sinal_credito_nasce'
                   and tgrelid = 'app.sinal_avisos'::regclass) then
    create trigger sinal_credito_nasce after update of status on app.sinal_avisos
      for each row execute function app.sinal_credito_nasce();
  end if;
end $$;

-- 2. Nova reserva: o crédito entra sozinho.
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
      '💳 ' || v_nome || ' marcou de novo e usou o sinal de *R$ ' || app.agenda_reais_curto(v_cr.valor_centavos)
      || '* que tinha pago depois do prazo: ' || app.sinal_o_que(v_a.id) || '. Já está confirmado.',
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
revoke all on function app.sinal_credito_usa() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'sinal_credito_usa'
                   and tgrelid = 'app.appointment_deposits'::regclass) then
    create trigger sinal_credito_usa after insert on app.appointment_deposits
      for each row execute function app.sinal_credito_usa();
  end if;
end $$;

-- O que aconteceu com o crédito neste agendamento (para a atendente).
create or replace function app.sinal_credito_do_agendamento(p_appointment_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $$
  select coalesce((
    select jsonb_build_object(
             'usado', true,
             'jeito', c.status,
             'valor', 'R$ ' || app.agenda_reais_curto(c.valor_centavos),
             'confirmado', (select a.status = 'CONFIRMED' from app.appointments a where a.id = p_appointment_id))
      from app.sinal_creditos c
     where c.usado_em_appointment_id = p_appointment_id
     order by c.resolvido_em desc limit 1), jsonb_build_object('usado', false));
$$;
revoke all on function app.sinal_credito_do_agendamento(uuid) from public, anon, authenticated;

-- O crédito disponível desta cliente (para a atendente saber e oferecer).
create or replace function app.sinal_credito_da_conversa(p_conversation_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'valor', 'R$ ' || app.agenda_reais_curto(cr.valor_centavos),
           'valeAte', to_char(cr.vence_em at time zone 'America/Sao_Paulo', 'DD/MM'),
           'deOnde', 'sinal pago depois do prazo')), '[]'::jsonb)
    from app.crm_conversations c
    join app.sinal_creditos cr
      on cr.tenant_id = c.tenant_id and cr.status = 'DISPONIVEL'
     and cr.contato_digitos = app.sinal_digitos(c.external_conversation_ref)
   where c.id = p_conversation_id;
$$;
revoke all on function app.sinal_credito_da_conversa(uuid) from public, anon, authenticated;

-- 3. Devolver: ela pediu, ou não há horário que sirva, ou venceu.
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
    || p_motivo || '. Devolva no Pix dela (telefone ' || v_cr.contato_digitos || '). Confirme a chave Pix com ela antes.',
    'sinal:credito-devolver:' || v_cr.id::text, v_cr.cliente_nome, null);
  return jsonb_build_object('ok', true, 'valor', 'R$ ' || app.agenda_reais_curto(v_cr.valor_centavos),
    'texto', 'O salão vai devolver o sinal de R$ ' || app.agenda_reais_curto(v_cr.valor_centavos)
             || ' no Pix dela; o dono já foi avisado.',
    'avisoAoDono', v_r);
end;
$$;
revoke all on function app.sinal_devolver_credito(uuid, text) from public, anon, authenticated;

-- A atendente devolve pelo número da conversa.
create or replace function app.sinal_devolver_credito_da_conversa(p_conversation_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id uuid;
begin
  select cr.id into v_id
    from app.crm_conversations c
    join app.sinal_creditos cr
      on cr.tenant_id = c.tenant_id and cr.status = 'DISPONIVEL'
     and cr.contato_digitos = app.sinal_digitos(c.external_conversation_ref)
   where c.id = p_conversation_id
   order by cr.criado_em limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'SEM_CREDITO',
      'texto', 'Ela não tem crédito de sinal. Não prometa devolução.');
  end if;
  return app.sinal_devolver_credito(v_id, coalesce(nullif(trim(p_motivo), ''), 'não achou horário que sirva para ela'));
end;
$$;
revoke all on function app.sinal_devolver_credito_da_conversa(uuid, text) from public, anon, authenticated;

-- 4. Crédito vencido (7 dias sem marcar): devolve. Roda junto da rotina do sinal.
create or replace function app.sinal_creditos_vencidos(p_agora timestamptz default null)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  r record;
  n integer := 0;
  v_conv uuid;
begin
  for r in select * from app.sinal_creditos
            where status = 'DISPONIVEL' and vence_em <= coalesce(p_agora, statement_timestamp())
  loop
    perform app.sinal_devolver_credito(r.id, 'não marcou outro horário em 7 dias');
    select c.id into v_conv from app.crm_conversations c
     where c.tenant_id = r.tenant_id and app.sinal_digitos(c.external_conversation_ref) = r.contato_digitos
     order by c.last_inbound_at desc nulls last limit 1;
    perform app.sinal_mandar_para_cliente(r.tenant_id, v_conv,
      'Oi' || coalesce(', ' || r.cliente_nome, '') || '! Como não conseguimos um novo horário pra você, '
      || 'o salão vai devolver o seu sinal de *R$ ' || app.agenda_reais_curto(r.valor_centavos)
      || '* no Pix 💛 Se quiser marcar depois, é só me chamar.',
      'sinal:credito-vencido:' || r.id::text);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function app.sinal_creditos_vencidos(timestamptz) from public, anon, authenticated;

-- Pontes.
create or replace function public.sinal_credito_do_agendamento(p_appointment_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.sinal_credito_do_agendamento(p_appointment_id); $$;
create or replace function public.sinal_credito_da_conversa(p_conversation_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.sinal_credito_da_conversa(p_conversation_id); $$;
create or replace function public.sinal_devolver_credito_da_conversa(p_conversation_id uuid, p_motivo text)
returns jsonb language sql security definer set search_path to ''
as $$ select app.sinal_devolver_credito_da_conversa(p_conversation_id, p_motivo); $$;
revoke all on function public.sinal_credito_do_agendamento(uuid) from public, anon, authenticated;
revoke all on function public.sinal_credito_da_conversa(uuid) from public, anon, authenticated;
revoke all on function public.sinal_devolver_credito_da_conversa(uuid, text) from public, anon, authenticated;
grant execute on function public.sinal_credito_do_agendamento(uuid) to service_role;
grant execute on function public.sinal_credito_da_conversa(uuid) to service_role;
grant execute on function public.sinal_devolver_credito_da_conversa(uuid, text) to service_role;

select cron.unschedule('sinal-creditos-vencidos') where exists (select 1 from cron.job where jobname = 'sinal-creditos-vencidos');
select cron.schedule('sinal-creditos-vencidos', '17 * * * *', $c$ select app.sinal_creditos_vencidos(); $c$);
