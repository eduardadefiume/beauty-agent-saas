-- ETAPA 5, parte 3: desfazer, e o que a tela enxerga.
--
-- DESFAZER É O QUE TORNA ISTO USÁVEL. "Deixa a IA preencher" só é uma oferta
-- honesta se voltar atrás custar um clique. Cada resposta guardou o valor
-- anterior; aqui ele volta.
--
-- O caso que exige cuidado é a REGRA: quando não existia regra nenhuma sobre o
-- assunto, a IA INSERIU uma. Desfazer ali não é restaurar texto, é arquivar a
-- linha -- restaurar `body = null` estouraria a constraint e deixaria uma
-- regra vazia valendo para a cliente.

create or replace function app.onboarding_undo(p_answer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_r      app.onboarding_answers;
  v_tipo   text;
  v_alvo   text;
  v_id     uuid;
begin
  select * into v_r from app.onboarding_answers where id = p_answer_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'RESPOSTA_NAO_EXISTE');
  end if;

  if v_r.status = 'PROPOSTO' then
    update app.onboarding_answers
       set status = 'RECUSADO', motivo = 'O dono descartou a proposta.',
           updated_at = statement_timestamp()
     where id = p_answer_id;
    return jsonb_build_object('ok', true, 'status', 'RECUSADO');
  end if;

  if v_r.status <> 'APLICADO' then
    return jsonb_build_object('ok', false, 'reason', 'NADA_A_DESFAZER');
  end if;

  v_tipo := split_part(v_r.pendency_key, ':', 1);
  v_alvo := substr(v_r.pendency_key, length(split_part(v_r.pendency_key, ':', 1)) + 2);

  if v_tipo = 'SERVICO_PRECO' then
    v_id := v_alvo::uuid;
    update app.services
       set base_price_minor = nullif(v_r.valor_anterior->>'base_price_minor', '')::integer,
           updated_at = statement_timestamp()
     where id = v_id and tenant_id = v_r.tenant_id;

  elsif v_tipo = 'COR_RESPOSTA' then
    update app.color_policies
       set answer_value = nullif(v_r.valor_anterior->>'answer_value', '')::numeric,
           answered_at = case when v_r.valor_anterior->>'answer_value' is null then null else answered_at end,
           answered_by = case when v_r.valor_anterior->>'answer_value' is null then null else answered_by end,
           updated_at = statement_timestamp()
     where tenant_id = v_r.tenant_id and key = v_alvo;

  elsif v_tipo = 'CONHECIMENTO_DESCRICAO' then
    v_id := v_alvo::uuid;
    update app.knowledge_options
       set description = v_r.valor_anterior->>'description',
           updated_at = statement_timestamp()
     where id = v_id and tenant_id = v_r.tenant_id;
    -- O carimbo de procedência volta junto: se o dono desfez, ele não ajustou.
    update app.knowledge_options
       set origin = v_r.valor_anterior->>'origin'
     where id = v_id and tenant_id = v_r.tenant_id
       and v_r.valor_anterior->>'origin' is not null;

  elsif v_tipo = 'REGRA' then
    if v_r.valor_anterior->>'body' is null then
      -- Não havia regra: arquivar é o desfazer certo. Apagar perderia o
      -- registro de que a IA chegou a escrever isto.
      update app.agent_policies
         set status = 'ARCHIVED', updated_at = statement_timestamp()
       where tenant_id = v_r.tenant_id and topic::text = v_alvo and status = 'ACTIVE'
         and body = v_r.valor_texto;
    else
      update app.agent_policies
         set body = v_r.valor_anterior->>'body', updated_at = statement_timestamp()
       where id = (v_r.valor_anterior->>'id')::uuid;
    end if;
  else
    return jsonb_build_object('ok', false, 'reason', 'DESTINO_FORA_DA_LISTA_BRANCA');
  end if;

  update app.onboarding_answers
     set status = 'DESFEITO', motivo = 'O dono desfez.', updated_at = statement_timestamp()
   where id = p_answer_id;

  return jsonb_build_object('ok', true, 'status', 'DESFEITO');
end;
$function$;

revoke all on function app.onboarding_undo(uuid) from public, anon, authenticated;
grant execute on function app.onboarding_undo(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- O que a tela lê
-- ---------------------------------------------------------------------------

create or replace function public.site_onboarding_state(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_sessao uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  select id into v_sessao from app.onboarding_sessions
   where tenant_id = target_tenant_id and status = 'ABERTA'
   order by started_at desc limit 1;

  return jsonb_build_object(
    'sessionId', v_sessao,
    -- A pauta: por módulo, quantas perguntas ainda estão de pé e as primeiras
    -- delas. A tela não precisa das 44 de uma vez para saber o tamanho do
    -- buraco.
    'pendencias', coalesce((
      select jsonb_agg(x order by x->>'modulo')
        from (
          select jsonb_build_object(
                   'modulo', p.modulo,
                   'quantas', count(*),
                   'primeiras', (array_agg(
                     jsonb_build_object('chave', p.chave, 'pergunta', p.pergunta, 'contexto', p.contexto)
                     order by p.prioridade, p.pergunta))[1:5]
                 ) as x
            from app.onboarding_pendencies(target_tenant_id) p
           group by p.modulo
        ) y
    ), '[]'::jsonb),
    'conversa', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'quem', t.quem, 'texto', t.texto,
               'midia', t.midia, 'erroLeitura', t.erro_leitura, 'quando', t.created_at
             ) order by t.created_at)
        from app.onboarding_turns t where t.session_id = v_sessao
    ), '[]'::jsonb),
    -- O que a IA mexeu nesta sessão, com o que estava lá antes. É a prestação
    -- de contas: sem ela, "a IA preencheu" seria um ato de fé.
    'respostas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'chave', a.pendency_key, 'modulo', a.modulo,
               'entendido', a.entendido, 'valorTexto', a.valor_texto,
               'valorNumero', a.valor_numero, 'confianca', a.confidence,
               'status', a.status, 'motivo', a.motivo,
               'valorAnterior', a.valor_anterior, 'quando', a.created_at
             ) order by a.created_at desc)
        from app.onboarding_answers a where a.session_id = v_sessao
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_onboarding_state(text, text, uuid) to service_role;

create or replace function public.site_onboarding_open(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_modulo          text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  -- Uma sessão aberta por vez. Duas conversas simultâneas escrevendo no mesmo
  -- rascunho seria a IA discutindo consigo mesma.
  select id into v_id from app.onboarding_sessions
   where tenant_id = target_tenant_id and status = 'ABERTA'
   order by started_at desc limit 1;

  if v_id is null then
    insert into app.onboarding_sessions (tenant_id, modulo, created_by)
    values (target_tenant_id,
            nullif(target_modulo, ''),
            target_email)
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'sessionId', v_id);
end;
$function$;

grant execute on function public.site_onboarding_open(text, text, uuid, text) to service_role;

create or replace function public.site_onboarding_undo(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_answer_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  -- A resposta tem que ser deste salão. Sem esta linha, um id vazado desfaria
  -- escrita em outro salão.
  if not exists (
    select 1 from app.onboarding_answers a
     where a.id = target_answer_id and a.tenant_id = target_tenant_id
  ) then
    return jsonb_build_object('ok', false, 'reason', 'RESPOSTA_NAO_E_DESTE_SALAO');
  end if;

  return app.onboarding_undo(target_answer_id);
end;
$function$;

grant execute on function public.site_onboarding_undo(text, text, uuid, uuid) to service_role;

create or replace function public.site_onboarding_close(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  update app.onboarding_sessions
     set status = 'ENCERRADA', ended_at = statement_timestamp()
   where tenant_id = target_tenant_id and status = 'ABERTA';

  return jsonb_build_object('ok', true);
end;
$function$;

grant execute on function public.site_onboarding_close(text, text, uuid) to service_role;
