-- O SINAL DESTA CLIENTE, EM CADA TURNO DA ATENDENTE.
-- 01/10, DEV: a Marina desmarcou as luzes com sinal pago (o dono já tinha
-- recebido "devolva R$ 100"), e depois perguntou "conseguiu desmarcar? e o
-- sinal que eu paguei?". A atendente só enxerga horários futuros marcados;
-- não sabia de nada e mandou a pergunta para o dono. O banco sabe tudo:
-- esperando pagamento (até quando), pago, desmarcado com devolução ou sem,
-- prazo vencido. Últimos 30 dias, do mais novo para o mais velho.
create or replace function app.sinal_da_cliente(p_conversation_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'atualizado' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'oQue', app.sinal_o_que(a.id),
               'valor', 'R$ ' || app.agenda_reais_curto(d.amount_cents),
               'situacao', case
                 when a.status = 'PENDING_SIGNAL' and d.status = 'PENDING'
                   then case when exists (select 1 from app.sinal_avisos s where s.appointment_id = a.id
                                            and s.tipo = 'COMPROVANTE' and s.status = 'ABERTO')
                             then 'comprovante enviado, esperando o salão conferir'
                             else 'esperando o pagamento até ' || app.sinal_quando(d.due_at, coalesce(u.timezone, 'America/Sao_Paulo'), statement_timestamp()) end
                 when a.status = 'CONFIRMED' and d.status = 'CONFIRMED' then 'sinal pago, horário confirmado'
                 when a.status = 'CANCELLED' and d.status = 'CONFIRMED' then
                   case when exists (select 1 from app.sinal_avisos s where s.appointment_id = a.id and s.tipo = 'DEVOLVER')
                        then 'desmarcado; o sinal VAI SER DEVOLVIDO pelo salão (o dono já foi avisado)'
                        when exists (select 1 from app.sinal_avisos s where s.appointment_id = a.id and s.tipo = 'NAO_DEVOLVE')
                        then 'desmarcado; pela regra do salão o sinal não é devolvido'
                        else 'desmarcado; o salão vai falar com ela sobre o sinal' end
                 when d.status = 'EXPIRED' then 'prazo do sinal venceu e o horário foi liberado'
                 when d.status = 'CANCELLED' then 'desmarcado antes de pagar'
                 else lower(d.status::text) end,
               'atualizado', greatest(a.updated_at, d.updated_at)) x
        from app.crm_conversations c
        join app.appointments a
          on a.tenant_id = c.tenant_id
         and right(regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g'), 11)
           = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 11)
        join app.appointment_deposits d on d.appointment_id = a.id and d.status <> 'NOT_REQUIRED'
        left join app.units u on u.id = a.unit_id
       where c.id = p_conversation_id
         and length(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g')) >= 8
         and greatest(a.updated_at, d.updated_at) > statement_timestamp() - interval '30 days'
    ) t;
$$;
revoke all on function app.sinal_da_cliente(uuid) from public, anon, authenticated;

create or replace function public.sinal_da_cliente(p_conversation_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.sinal_da_cliente(p_conversation_id); $$;
revoke all on function public.sinal_da_cliente(uuid) from public, anon, authenticated;
grant execute on function public.sinal_da_cliente(uuid) to service_role;
