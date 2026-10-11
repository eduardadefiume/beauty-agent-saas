-- A RETOMADA PERGUNTA TODOS OS PREÇOS DE UMA VEZ.
--
-- 11/10/2026, a Duda: a retomada do cadastro parado perguntava um serviço por
-- vez ("Quanto custa Coloração?"). Com 6 serviços sem preço, seriam 6
-- retomadas -- e o limite é 3. Faltando preço de mais de um serviço, a
-- pergunta lista todos: "quanto custa cada serviço: Coloração, Corte, ... e
-- Selante? Pode ser tudo numa mensagem só, tipo: corte R$ 80, escova R$ 50."

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
  v_chave    text;
  v_qtd      integer;
  v_lista    text;
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

    select p.pergunta, p.chave into v_pergunta, v_chave
      from app.onboarding_pendencies(v_c.tenant_id) p
     order by p.prioridade, p.pergunta
     limit 1;
    continue when v_pergunta is null;
    -- Faltando preço de mais de um serviço, pergunta todos de uma vez.
    if v_chave like 'SERVICO_PRECO:%' then
      select count(*), string_agg(substring(p.pergunta from '^Quanto custa (.*)\?$'), ', ' order by p.pergunta)
        into v_qtd, v_lista
        from app.onboarding_pendencies(v_c.tenant_id) p
       where p.chave like 'SERVICO_PRECO:%';
      if v_qtd > 1 then
        v_lista := regexp_replace(v_lista, ', ([^,]*)$', ' e \1');
        v_pergunta := 'quanto custa cada serviço: ' || v_lista
          || '? Pode ser tudo numa mensagem só, tipo: corte R$ 80, escova R$ 50.';
      end if;
    end if;
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
