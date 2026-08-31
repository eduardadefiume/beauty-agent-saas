-- O primeiro agendamento que o agente conseguiu marcar entrou na agenda sem
-- nome nenhum: customer_label null. Na agenda do William isso aparece como um
-- bloco de quatro horas de sabado sem dono.
--
-- Causa: o agente rotula o agendamento com contact.displayName, que e o nome
-- do perfil do WhatsApp -- e esse contato nao tem. Mas a ficha tinha
-- "Eduarda" desde as 09:32, porque ela mesma disse o nome na conversa.
--
-- Correcao: quando o perfil do WhatsApp nao traz nome, o contexto usa o nome
-- que a cliente deu. Nao sobrescreve nada: o nome do perfil, quando existe,
-- continua ganhando. Vale para todo mundo que le o contexto, nao so para o
-- rotulo do agendamento.
do $$
declare
  antes    constant text := $t$'displayName', v_c.display_name,$t$;
  depois   constant text := $t$'displayName', coalesce(v_c.display_name, nullif(trim(v_cliente->>'preferredName'), '')),$t$;
  definicao text;
begin
  select pg_get_functiondef(p.oid)
    into definicao
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname = 'build_agent_context';

  if definicao is null then
    raise exception 'app.build_agent_context nao existe';
  end if;

  if position(depois in definicao) > 0 then
    raise notice 'o contexto ja usa o nome da ficha, nada a fazer';
    return;
  end if;

  if position(antes in definicao) = 0 then
    raise exception 'o bloco contact de build_agent_context nao esta como esperado; nada foi alterado';
  end if;

  execute replace(definicao, antes, depois);
end $$;

-- O agendamento que ja existe recebe o nome que faltou.
update app.appointments
   set customer_label = 'Eduarda'
 where id = '7d1ed5b9-639e-458b-89db-286a31b5964f'
   and customer_label is null;
