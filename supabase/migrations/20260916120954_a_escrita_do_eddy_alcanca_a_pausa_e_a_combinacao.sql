create or replace function app.servico_no_rascunho(p_tenant_id uuid, p_service_id uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_nome text;
  v_rascunho uuid;
  v_id uuid;
begin
  select s.name into v_nome
    from app.services s
   where s.id = p_service_id and s.tenant_id = p_tenant_id;
  if v_nome is null then
    return null;
  end if;

  v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);

  select s.id into v_id
    from app.services s
   where s.tenant_id = p_tenant_id
     and s.configuration_draft_id = v_rascunho
     and s.name = v_nome
     and s.status = 'ACTIVE'
   limit 1;

  return v_id;
end;
$function$;

revoke all on function app.servico_no_rascunho(uuid, uuid) from public, anon, authenticated;

create or replace function app.onboarding_write(p_tenant_id uuid, p_key text, p_valor_texto text, p_valor_numero numeric)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tipo      text := split_part(p_key, ':', 1);
  v_alvo      text := substr(p_key, length(split_part(p_key, ':', 1)) + 2);
  v_antes     jsonb;
  v_id        uuid;
  v_alvo_id   uuid;
  v_topico    text;
  v_libera    boolean;
  v_pos       integer;
  v_rascunho  uuid;
begin
  if v_alvo = '' then
    return jsonb_build_object('ok', false, 'reason', 'CHAVE_SEM_ALVO');
  end if;

  if v_tipo = 'SERVICO_PRECO' then
    if p_valor_numero is null or p_valor_numero <= 0 or p_valor_numero > 100000 then
      return jsonb_build_object('ok', false, 'reason', 'PRECO_FORA_DE_FAIXA');
    end if;
    begin v_id := v_alvo::uuid; exception when others then
      return jsonb_build_object('ok', false, 'reason', 'ALVO_INVALIDO');
    end;

    v_alvo_id := app.servico_no_rascunho(p_tenant_id, v_id);
    if v_alvo_id is null then
      return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO_NO_RASCUNHO');
    end if;

    select jsonb_build_object('base_price_minor', s.base_price_minor)
      into v_antes from app.services s where s.id = v_alvo_id;

    update app.services
       set base_price_minor = round(p_valor_numero * 100)::integer,
           updated_at = statement_timestamp()
     where id = v_alvo_id and tenant_id = p_tenant_id;

    return jsonb_build_object('ok', true, 'antes', v_antes);

  elsif v_tipo = 'SERVICO_PAUSA' then
    if p_valor_numero is null or p_valor_numero < 0 or p_valor_numero > 300 then
      return jsonb_build_object('ok', false, 'reason', 'PAUSA_FORA_DE_FAIXA');
    end if;
    begin v_id := v_alvo::uuid; exception when others then
      return jsonb_build_object('ok', false, 'reason', 'ALVO_INVALIDO');
    end;

    if p_valor_numero = 0 then
      return jsonb_build_object('ok', true, 'antes', jsonb_build_object('pausa', 'nenhuma'));
    end if;

    v_alvo_id := app.servico_no_rascunho(p_tenant_id, v_id);
    if v_alvo_id is null then
      return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO_NO_RASCUNHO');
    end if;

    select s.configuration_draft_id into v_rascunho from app.services s where s.id = v_alvo_id;

    v_libera := coalesce(p_valor_texto, '') ~* '(consigo|dá para|da para|libera|atendo|sim|outra cliente|posso)';

    select st.position into v_pos
      from app.service_steps st
     where st.service_id = v_alvo_id and st.name ilike 'aplica%'
     order by st.position desc limit 1;

    if v_pos is null then
      select coalesce(max(st.position), 0) into v_pos
        from app.service_steps st where st.service_id = v_alvo_id;
    else
      update app.service_steps
         set position = position + 1
       where service_id = v_alvo_id and position > v_pos;
    end if;

    insert into app.service_steps (
      tenant_id, configuration_draft_id, service_id, name, position, duration_minutes,
      kind, customer_presence_required, releases_member,
      minimum_duration_minutes, maximum_duration_minutes
    ) values (
      p_tenant_id, v_rascunho, v_alvo_id, 'Pausa', v_pos + 1, round(p_valor_numero)::integer,
      'PASSIVE', true, v_libera, round(p_valor_numero)::integer, round(p_valor_numero)::integer
    );

    return jsonb_build_object('ok', true, 'antes', jsonb_build_object('pausa', 'nenhuma'));

  elsif v_tipo = 'SERVICO_PAUSA_LIBERA' then
    if p_valor_numero is null or p_valor_numero not in (0, 1) then
      return jsonb_build_object('ok', false, 'reason', 'RESPOSTA_PRECISA_SER_SIM_OU_NAO');
    end if;
    begin v_id := v_alvo::uuid; exception when others then
      return jsonb_build_object('ok', false, 'reason', 'ALVO_INVALIDO');
    end;

    v_alvo_id := app.servico_no_rascunho(p_tenant_id, v_id);
    if v_alvo_id is null then
      return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO_NO_RASCUNHO');
    end if;

    select jsonb_build_object('releases_member', bool_or(st.releases_member))
      into v_antes
      from app.service_steps st
     where st.service_id = v_alvo_id and st.kind = 'PASSIVE';

    update app.service_steps
       set releases_member = (p_valor_numero = 1), updated_at = statement_timestamp()
     where service_id = v_alvo_id and kind = 'PASSIVE';

    return jsonb_build_object('ok', true, 'antes', v_antes);

  elsif v_tipo = 'COMBINACAO' then
    if coalesce(trim(p_valor_texto), '') = '' or length(trim(p_valor_texto)) < 5 then
      return jsonb_build_object('ok', false, 'reason', 'REGRA_VAZIA');
    end if;
    if length(trim(p_valor_texto)) > 2000 then
      return jsonb_build_object('ok', false, 'reason', 'REGRA_LONGA_DEMAIS');
    end if;

    insert into app.agent_policies (tenant_id, topic, title, body, status, position)
    values (p_tenant_id, 'PROCEDIMENTO'::app.policy_topic,
            'Combinação: ' || replace(v_alvo, '-', ' com '),
            trim(p_valor_texto), 'ACTIVE',
            coalesce((select max(position) + 1 from app.agent_policies where tenant_id = p_tenant_id), 1));

    return jsonb_build_object('ok', true, 'antes', jsonb_build_object('body', null));

  elsif v_tipo = 'COR_RESPOSTA' then
    if p_valor_numero is null or p_valor_numero < 0 then
      return jsonb_build_object('ok', false, 'reason', 'RESPOSTA_INVALIDA');
    end if;

    select jsonb_build_object('answer_value', c.answer_value)
      into v_antes
      from app.color_policies c
     where c.tenant_id = p_tenant_id and c.key = v_alvo;
    if v_antes is null then
      return jsonb_build_object('ok', false, 'reason', 'PERGUNTA_NAO_E_DESTE_SALAO');
    end if;

    update app.color_policies
       set answer_value = p_valor_numero,
           answered_at = statement_timestamp(),
           answered_by = 'AGENTE_ONBOARDING',
           updated_at = statement_timestamp()
     where tenant_id = p_tenant_id and key = v_alvo;

    return jsonb_build_object('ok', true, 'antes', v_antes);

  elsif v_tipo = 'CONHECIMENTO_DESCRICAO' then
    if coalesce(trim(p_valor_texto), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'DESCRICAO_VAZIA');
    end if;
    begin v_id := v_alvo::uuid; exception when others then
      return jsonb_build_object('ok', false, 'reason', 'ALVO_INVALIDO');
    end;

    select jsonb_build_object('description', o.description, 'origin', o.origin)
      into v_antes
      from app.knowledge_options o
     where o.id = v_id and o.tenant_id = p_tenant_id;
    if v_antes is null then
      return jsonb_build_object('ok', false, 'reason', 'OPCAO_NAO_E_DESTE_SALAO');
    end if;

    update app.knowledge_options
       set description = trim(p_valor_texto), updated_at = statement_timestamp()
     where id = v_id and tenant_id = p_tenant_id;

    return jsonb_build_object('ok', true, 'antes', v_antes);

  elsif v_tipo = 'REGRA' then
    if coalesce(trim(p_valor_texto), '') = '' or length(trim(p_valor_texto)) < 2 then
      return jsonb_build_object('ok', false, 'reason', 'REGRA_VAZIA');
    end if;
    if length(trim(p_valor_texto)) > 2000 then
      return jsonb_build_object('ok', false, 'reason', 'REGRA_LONGA_DEMAIS');
    end if;
    if v_alvo not in ('PAGAMENTO', 'CANCELAMENTO', 'ATRASO', 'SINAL',
                      'VOZ', 'PRECO', 'AVALIACAO', 'AGENDAMENTO',
                      'PROCEDIMENTO', 'PROMOCAO', 'FOTOS', 'ATENDIMENTO', 'OUTRO') then
      return jsonb_build_object('ok', false, 'reason', 'ASSUNTO_DESCONHECIDO');
    end if;
    v_topico := v_alvo;

    insert into app.agent_policies (tenant_id, topic, title, body, status, position)
    values (p_tenant_id, v_topico::app.policy_topic,
            initcap(lower(v_topico)), trim(p_valor_texto), 'ACTIVE',
            coalesce((select max(position) + 1 from app.agent_policies where tenant_id = p_tenant_id), 1));

    return jsonb_build_object('ok', true, 'antes', jsonb_build_object('body', null));
  end if;

  return jsonb_build_object('ok', false, 'reason', 'DESTINO_FORA_DA_LISTA_BRANCA');
end;
$function$;

revoke all on function app.onboarding_write(uuid, text, text, numeric) from public, anon, authenticated;