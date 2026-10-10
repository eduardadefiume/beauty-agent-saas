-- O VIGIA TAMBÉM OLHA O SALÃO AINDA NÃO PUBLICADO (10/10/2026).
--
-- O William escreveu "Oi" duas vezes (08 e 09/10) pelo WhatsApp do salão
-- (16 99131-9581), que não estava cadastrado como dono. Para o sistema foi
-- uma cliente; a atendente estava desligada (salão não publicado) e o vigia
-- ignorava salão com a atendente desligada. Ninguém respondeu, ninguém soube.
-- Mensagem sem resposta é alerta qualquer que seja o motivo: com a atendente
-- desligada, o alerta diz isso (pode ser o dono por um número não cadastrado).

create or replace function app.mensagens_sem_resposta(p_minutos integer default 15)
returns table (message_id uuid, tenant_id uuid, conversation_id uuid, desde timestamptz, quem text)
language sql
stable
security definer
set search_path to ''
as $function$
  with ultima as (
    select distinct on (m.tenant_id, m.conversation_id)
           m.id, m.tenant_id, m.conversation_id, m.direction, m.occurred_at,
           coalesce(m.metadata_minimized->>'agentDecision', '') as decisao
      from app.crm_messages m
     where m.occurred_at > statement_timestamp() - interval '7 days'
       and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
     order by m.tenant_id, m.conversation_id, m.occurred_at desc
  )
  select u.id, u.tenant_id, u.conversation_id, u.occurred_at,
         case
           when app.conversa_e_do_dono(u.conversation_id) then 'dono'
           when not app.agent_automation_enabled(u.tenant_id) then 'desligada'
           else 'cliente'
         end
    from ultima u
    join app.crm_conversations c on c.tenant_id = u.tenant_id and c.id = u.conversation_id
    join app.channel_connections ch on ch.id = c.channel_connection_id and ch.tenant_id = c.tenant_id
   where u.direction = 'INBOUND'
     -- Olha o que saiu, não a marca: REPLY sem mensagem depois é silêncio
     -- (07/10: envio recusado pela janela de 24h). HANDOFF já tem alerta próprio.
     and u.decisao <> 'HANDOFF'
     and u.occurred_at < statement_timestamp() - make_interval(mins => greatest(coalesce(p_minutos, 15), 1))
     and ch.status not in ('DISCONNECTED', 'SUSPENDED')
     and not app.e_da_operadora(c.external_conversation_ref)
     and not exists (
       select 1 from app.agent_conversation_pause p
        where p.tenant_id = u.tenant_id and p.conversation_id = u.conversation_id and p.paused)
     and not exists (
       select 1 from app.mensagens_sem_resposta_avisadas a where a.message_id = u.id);
$function$;

create or replace function app.vigiar_sem_resposta()
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_m  record;
  v_n  integer := 0;
  v_quem text;
  v_final text;
begin
  for v_m in select * from app.mensagens_sem_resposta(15) limit 20 loop
    select right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 4)
      into v_final
      from app.crm_conversations c where c.id = v_m.conversation_id;

    v_quem := case v_m.quem
      when 'dono' then 'o dono (Eddy)'
      when 'desligada' then 'o número final ' || coalesce(v_final, '?')
        || ' — a atendente está desligada (salão não publicado). Se for o dono por outro número, cadastre o número'
      else 'a cliente final ' || coalesce(v_final, '?')
    end;

    insert into app.mensagens_sem_resposta_avisadas (message_id, tenant_id)
    values (v_m.message_id, v_m.tenant_id)
    on conflict do nothing;

    perform app.raise_agent_alert(
      v_m.tenant_id, 'SEM_RESPOSTA',
      'Quem espera: ' || v_quem || ', desde '
      || to_char(v_m.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
      || ' [conversa ' || left(v_m.conversation_id::text, 8) || ']');
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

revoke all on function app.mensagens_sem_resposta(integer) from public, anon, authenticated;
revoke all on function app.vigiar_sem_resposta() from public, anon, authenticated;
