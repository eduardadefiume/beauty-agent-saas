-- ETAPA 5, parte 2: a conversa, e o que ela pode escrever.
--
-- A IDEIA. O dono fala do jeito dele -- "escova sessenta, escova com prancha
-- oitenta, progressiva a partir de trezentos" -- e a IA transforma isso em
-- linha de catálogo. É o contrário do configurador: em vez de o dono aprender
-- a estrutura do sistema, o sistema aprende a falar como ele.
--
-- O RISCO, E A TRAVA. Uma IA lendo áudio pode entender "sessenta" onde o dono
-- disse "setenta". Se ela pudesse escrever em qualquer lugar, um erro de
-- transcrição viraria preço errado que o agente promete para a cliente.
--
-- Então a escrita passa por uma LISTA BRANCA de quatro destinos, e nada além
-- deles é alcançável, não importa o que o modelo devolva:
--
--   SERVICO_PRECO            -> app.services.base_price_minor (só no RASCUNHO)
--   COR_RESPOSTA             -> app.color_policies.answer_value
--   CONHECIMENTO_DESCRICAO   -> app.knowledge_options.description
--   REGRA                    -> app.agent_policies (regra nova, nas palavras dele)
--
-- Três dessas quatro são reversíveis por natureza. A primeira é a mais segura
-- de todas e não por acaso: preço entra no RASCUNHO, que não vale para
-- ninguém até o dono publicar. É literalmente "preencher o rascunho".
--
-- O QUE FICA MARCADO COMO INCERTO. Abaixo de 0,75 de confiança a IA não
-- escreve: registra como PROPOSTO e mostra ao dono. É o mesmo limite do motor
-- que classifica foto de cabelo, e pelo mesmo motivo -- abaixo dele o palpite
-- custa mais caro do que a pergunta.
--
-- Toda escrita guarda o valor anterior. Desfazer é um clique, e sem isso
-- "deixa a IA preencher" seria uma aposta em vez de uma ferramenta.

create table if not exists app.onboarding_sessions (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references app.tenants(id) on delete cascade,
  modulo     text check (modulo is null or modulo in ('SERVICOS', 'COR', 'CONHECIMENTO', 'REGRAS')),
  status     text not null default 'ABERTA' check (status in ('ABERTA', 'ENCERRADA')),
  started_at timestamptz not null default statement_timestamp(),
  ended_at   timestamptz,
  created_by text
);

create table if not exists app.onboarding_turns (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references app.onboarding_sessions(id) on delete cascade,
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  quem         text not null check (quem in ('DONO', 'SISTEMA')),
  -- Para o dono: o que ele digitou, ou a transcrição do que ele falou. Para o
  -- sistema: a pergunta ou o resumo do que entendeu.
  texto        text,
  midia        text check (midia is null or midia in ('AUDIO', 'FOTO')),
  storage_path text,
  erro_leitura text,
  created_at   timestamptz not null default statement_timestamp()
);

create index if not exists onboarding_turns_por_sessao_idx
  on app.onboarding_turns (session_id, created_at);

create table if not exists app.onboarding_answers (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references app.tenants(id) on delete cascade,
  session_id     uuid not null references app.onboarding_sessions(id) on delete cascade,
  turn_id        uuid references app.onboarding_turns(id) on delete set null,
  pendency_key   text not null,
  modulo         text not null,
  -- O que a IA entendeu, em português, para o dono conferir sem precisar
  -- traduzir estrutura de banco.
  entendido      text not null,
  valor_texto    text,
  valor_numero   numeric,
  confidence     numeric(4,3) check (confidence is null or (confidence >= 0 and confidence <= 1)),
  status         text not null check (status in ('APLICADO', 'PROPOSTO', 'RECUSADO', 'DESFEITO')),
  motivo         text,
  -- O que estava lá antes. É isto que torna desfazer possível.
  valor_anterior jsonb,
  applied_at     timestamptz,
  created_at     timestamptz not null default statement_timestamp(),
  updated_at     timestamptz not null default statement_timestamp()
);

create index if not exists onboarding_answers_por_sessao_idx
  on app.onboarding_answers (session_id, created_at desc);
create index if not exists onboarding_answers_abertas_idx
  on app.onboarding_answers (tenant_id, status) where status = 'PROPOSTO';

comment on table app.onboarding_answers is
  'O que a IA entendeu de cada fala do dono, o que escreveu e o que estava lá antes. Nada aqui é irreversível.';

-- ---------------------------------------------------------------------------
-- A lista branca
-- ---------------------------------------------------------------------------
--
-- Devolve o valor anterior quando escreve, ou {ok:false, reason} quando
-- recusa. Recusar é o caminho normal: chave que não é deste salão, alvo que
-- não existe mais, valor fora de faixa.

create or replace function app.onboarding_write(
  p_tenant_id    uuid,
  p_key          text,
  p_valor_texto  text,
  p_valor_numero numeric
)
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
  v_topico    text;
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

    -- Só no rascunho, e só se o serviço for mesmo deste salão. As duas
    -- condições juntas: a primeira impede mexer no que já está publicado, a
    -- segunda impede o modelo alcançar outro salão com um id inventado.
    select jsonb_build_object('base_price_minor', s.base_price_minor)
      into v_antes
      from app.services s
      join app.configuration_drafts d
        on d.id = s.configuration_draft_id and d.status = 'DRAFT'
     where s.id = v_id and s.tenant_id = p_tenant_id;
    if v_antes is null then
      return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ESTA_NO_RASCUNHO_DESTE_SALAO');
    end if;

    update app.services
       set base_price_minor = round(p_valor_numero * 100)::integer,
           updated_at = statement_timestamp()
     where id = v_id and tenant_id = p_tenant_id;

    return jsonb_build_object('ok', true, 'antes', v_antes);

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

    -- O gatilho da etapa 4 carimba PRODUTO_AJUSTADO sozinho: o dono
    -- reescreveu, mesmo que tenha reescrito falando.
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

    select jsonb_build_object('id', ap.id, 'body', ap.body)
      into v_antes
      from app.agent_policies ap
     where ap.tenant_id = p_tenant_id and ap.topic::text = v_topico and ap.status = 'ACTIVE'
     order by ap.position, ap.created_at
     limit 1;

    if v_antes is null then
      insert into app.agent_policies (tenant_id, topic, title, body, status, position)
      values (p_tenant_id, v_topico::app.policy_topic,
              initcap(lower(v_topico)), trim(p_valor_texto), 'ACTIVE',
              coalesce((select max(position) + 1 from app.agent_policies where tenant_id = p_tenant_id), 1));
      return jsonb_build_object('ok', true, 'antes', jsonb_build_object('body', null));
    end if;

    update app.agent_policies
       set body = trim(p_valor_texto), updated_at = statement_timestamp()
     where id = (v_antes->>'id')::uuid;
    return jsonb_build_object('ok', true, 'antes', v_antes);
  end if;

  return jsonb_build_object('ok', false, 'reason', 'DESTINO_FORA_DA_LISTA_BRANCA');
end;
$function$;

revoke all on function app.onboarding_write(uuid, text, text, numeric) from public, anon, authenticated;
grant execute on function app.onboarding_write(uuid, text, text, numeric) to service_role;

-- ---------------------------------------------------------------------------
-- Registrar o que a IA entendeu, e decidir se escreve
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_record_answer(
  p_session_id   uuid,
  p_turn_id      uuid,
  p_key          text,
  p_modulo       text,
  p_entendido    text,
  p_valor_texto  text,
  p_valor_numero numeric,
  p_confidence   numeric
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  c_limite constant numeric := 0.75;
  v_tenant uuid;
  v_escrita jsonb;
  v_status text;
  v_motivo text;
  v_id     uuid;
begin
  select tenant_id into v_tenant from app.onboarding_sessions where id = p_session_id;
  if v_tenant is null then
    return jsonb_build_object('ok', false, 'reason', 'SESSAO_NAO_EXISTE');
  end if;

  if coalesce(p_confidence, 0) < c_limite then
    v_status := 'PROPOSTO';
    v_motivo := 'Confiança abaixo do limite: a IA não escreveu, só anotou o que achou que entendeu.';
  else
    v_escrita := app.onboarding_write(v_tenant, p_key, p_valor_texto, p_valor_numero);
    if (v_escrita->>'ok')::boolean then
      v_status := 'APLICADO';
    else
      v_status := 'RECUSADO';
      v_motivo := v_escrita->>'reason';
    end if;
  end if;

  insert into app.onboarding_answers
    (tenant_id, session_id, turn_id, pendency_key, modulo, entendido,
     valor_texto, valor_numero, confidence, status, motivo, valor_anterior, applied_at)
  values
    (v_tenant, p_session_id, p_turn_id, p_key, p_modulo, p_entendido,
     p_valor_texto, p_valor_numero, p_confidence, v_status, v_motivo,
     v_escrita->'antes',
     case when v_status = 'APLICADO' then statement_timestamp() end)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'status', v_status, 'motivo', v_motivo);
end;
$function$;

revoke all on function app.onboarding_record_answer(uuid, uuid, text, text, text, text, numeric, numeric)
  from public, anon, authenticated;
grant execute on function app.onboarding_record_answer(uuid, uuid, text, text, text, text, numeric, numeric)
  to service_role;
