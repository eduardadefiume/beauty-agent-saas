-- O EDDY RETOMA SOZINHO O CADASTRO PARADO.
--
-- 11/10/2026, PRODUÇÃO, S-William: o William ligou o sinal em 10/10 às 08:20,
-- o Eddy respondeu sem pergunta nenhuma e a conversa morreu. Passadas 24h o
-- WhatsApp só aceita modelo aprovado, e ninguém voltava a falar com ele.
--
-- De hora em hora: dono com cadastro pela metade (há pendência no roteiro),
-- conversa parada há mais de 24h, recebe o modelo continuar_cadastro com a
-- próxima pergunta do roteiro dele. Sem IA, sem custo além da mensagem.
-- Limites para não virar spam: 1 retomada a cada 48h, 3 no total por
-- conversa, só das 9h às 20h de Brasília, só com o modelo aprovado.

create table if not exists app.retomadas_de_cadastro (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references app.tenants(id) on delete cascade,
  conversation_id uuid not null,
  pergunta        text not null,
  enviada_em      timestamptz not null default statement_timestamp(),
  resultado       jsonb
);

alter table app.retomadas_de_cadastro enable row level security;

create index if not exists retomadas_de_cadastro_conversa
  on app.retomadas_de_cadastro (conversation_id, enviada_em desc);

create or replace function app.retomar_cadastro_parado()
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_c        record;
  v_pergunta text;
  v_nome     text;
  v_salao    text;
  v_r        jsonb;
  v_n        integer := 0;
  v_hora     integer := extract(hour from statement_timestamp() at time zone 'America/Sao_Paulo');
begin
  if v_hora < 9 or v_hora >= 20 then
    return 0;
  end if;

  for v_c in
    select cv.id as conversation_id, cv.tenant_id,
           (select max(m.occurred_at) from app.crm_messages m
             where m.conversation_id = cv.id and m.message_type <> 'SYSTEM') as ultima
      from app.crm_conversations cv
      join app.channel_connections cc on cc.id = cv.channel_connection_id
     where cv.status = 'OPEN'
       and not coalesce(cc.simulado, false)
       and (cc.purpose = 'DONO' or app.conversa_e_do_dono(cv.id))
       and not app.e_da_operadora(cv.external_conversation_ref)
       and exists (
         select 1 from app.message_templates t
          where t.tenant_id = cv.tenant_id and t.code = 'CONTINUAR_CADASTRO' and t.status = 'APPROVED')
       and not exists (
         select 1 from app.agent_conversation_pause p
          where p.conversation_id = cv.id and p.paused)
  loop
    continue when v_c.ultima is null or v_c.ultima > statement_timestamp() - interval '24 hours';
    continue when exists (
      select 1 from app.retomadas_de_cadastro r
       where r.conversation_id = v_c.conversation_id
         and r.enviada_em > statement_timestamp() - interval '48 hours');
    continue when (select count(*) from app.retomadas_de_cadastro r
                    where r.conversation_id = v_c.conversation_id) >= 3;

    select p.pergunta into v_pergunta
      from app.onboarding_pendencies(v_c.tenant_id) p
     order by p.prioridade, p.pergunta
     limit 1;
    continue when v_pergunta is null;
    -- A Meta recusa parâmetro com quebra de linha ou tabulação.
    v_pergunta := btrim(regexp_replace(v_pergunta, '\s+', ' ', 'g'));

    select nullif(trim(o.display_name), '') into v_nome
      from app.owner_whatsapp o
     where o.tenant_id = v_c.tenant_id and o.status = 'ACTIVE'
     order by o.display_name nulls last limit 1;
    select coalesce(nullif(trim(t.display_name), ''), 'seu salão') into v_salao
      from app.tenants t where t.id = v_c.tenant_id;

    v_r := app.enqueue_outbound_template(
      v_c.tenant_id, v_c.conversation_id, 'CONTINUAR_CADASTRO',
      jsonb_build_array(coalesce(v_nome, 'tudo bem'), v_salao, v_pergunta),
      'retomada:' || v_c.conversation_id || ':' || to_char(statement_timestamp(), 'YYYYMMDD'),
      'Olá, ' || coalesce(v_nome, 'tudo bem') || '! Aqui é o Eddy, do ' || v_salao
        || '. Para a atendente ficar pronta, falta uma informação sua: ' || v_pergunta
        || ' Pode responder por aqui mesmo, escrito ou por áudio.');

    insert into app.retomadas_de_cadastro (tenant_id, conversation_id, pergunta, resultado)
    values (v_c.tenant_id, v_c.conversation_id, v_pergunta, v_r);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

revoke all on function app.retomar_cadastro_parado() from public, anon, authenticated;

select cron.schedule('eddy-retoma-cadastro', '7 * * * *', $c$ select app.retomar_cadastro_parado(); $c$);
