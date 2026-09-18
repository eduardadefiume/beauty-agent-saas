-- O EDDY GANHA MAO PARA CRIAR SERVICO E PARA PUBLICAR NO COMANDO DO DONO.
--
-- Ate aqui o Eddy so editava. A lista branca de app.onboarding_write exige que o
-- alvo ja exista, e a chave tem que vir de app.onboarding_pendencies -- "voce
-- nunca inventa uma". A trava esta certa para RESPONDER pendencia, mas ela
-- impede por construcao o ato que nao tem pendencia previa: criar.
--
-- Quem criava servico era so o configurador, pelo navegador. Isso nao escala
-- para N saloes: o dono fala por WhatsApp, e o cadastro precisa nascer dali.
--
-- Esta migration NAO afrouxa nenhuma trava existente. Ela acrescenta verbos
-- novos, cada um com a sua propria trava:
--
--   criar servico -> a habilidade vem de lista fechada (as que o salao ja tem,
--                    com gente ativa que sabe fazer). A engine de prontidao
--                    continua sendo quem decide se aquilo pode ir ao ar.
--
--   publicar      -> a autoridade NAO e do Eddy. Ele e OPERATOR e continua sem
--                    poder publicar. Ele so repassa o comando de um numero que
--                    esta em app.owner_whatsapp, e quem publica de fato e
--                    public.site_publish_configuration com o e-mail do dono --
--                    que continua exigindo OWNER/ADMIN, revisao esperada e
--                    prontidao. A frase do dono fica no audit_logs.

-- ---------------------------------------------------------------------------
-- 1. A lista fechada de habilidades. O Eddy escolhe daqui; nunca inventa.
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_habilidades(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  with rascunho as (
    select d.id
      from app.configuration_drafts d
     where d.tenant_id = p_tenant_id
     order by (d.status = 'DRAFT') desc, d.revision desc
     limit 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nome', k.name,
           'quemFaz', (
             select coalesce(jsonb_agg(m.name order by m.name), '[]'::jsonb)
               from app.member_skills ms
               join app.team_members m
                 on m.tenant_id = ms.tenant_id
                and m.configuration_draft_id = ms.configuration_draft_id
                and m.id = ms.member_id
                and m.status = 'ACTIVE'
              where ms.tenant_id = k.tenant_id
                and ms.configuration_draft_id = k.configuration_draft_id
                and ms.skill_id = k.id
           )
         ) order by k.name), '[]'::jsonb)
    from app.skills k, rascunho r
   where k.tenant_id = p_tenant_id
     and k.configuration_draft_id = r.id
     and k.status = 'ACTIVE'
     and exists (
       select 1
         from app.member_skills ms
         join app.team_members m
           on m.tenant_id = ms.tenant_id
          and m.configuration_draft_id = ms.configuration_draft_id
          and m.id = ms.member_id
          and m.status = 'ACTIVE'
        where ms.tenant_id = k.tenant_id
          and ms.configuration_draft_id = k.configuration_draft_id
          and ms.skill_id = k.id
     );
$fn$;

comment on function app.onboarding_habilidades(uuid) is
  'As habilidades que este salao tem E que alguem ativo sabe fazer. E a lista fechada de onde o Eddy escolhe ao criar servico: habilidade sem gente ativa nao entra, porque servico assim nunca passaria na prontidao.';

revoke all on function app.onboarding_habilidades(uuid) from public, anon, authenticated;
grant execute on function app.onboarding_habilidades(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Criar servico. Servico + passo + exigencia de habilidade, de uma vez.
--
-- Os tres juntos porque a engine de prontidao cobra os tres: um servico sem
-- passo cai em SERVICE_HAS_NO_STEPS, e um passo sem habilidade com gente cai em
-- STEP_HAS_NO_QUALIFIED_MEMBER. Criar so a linha de servico seria criar algo
-- que nunca poderia ser publicado -- e o dono descobriria isso depois.
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_criar_servico(
  p_tenant_id    uuid,
  p_nome         text,
  p_habilidade   text,
  p_duracao_min  integer,
  p_preco_reais  numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome      text := nullif(trim(coalesce(p_nome, '')), '');
  v_hab       text := nullif(trim(coalesce(p_habilidade, '')), '');
  v_rascunho  uuid;
  v_skill     uuid;
  v_servico   uuid;
  v_passo     uuid;
begin
  if v_nome is null or length(v_nome) < 3 or length(v_nome) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_FORA_DE_FAIXA');
  end if;

  if p_duracao_min is null or p_duracao_min < 5 or p_duracao_min > 600 then
    return jsonb_build_object('ok', false, 'reason', 'DURACAO_FORA_DE_FAIXA');
  end if;

  if p_preco_reais is not null and (p_preco_reais <= 0 or p_preco_reais > 100000) then
    return jsonb_build_object('ok', false, 'reason', 'PRECO_FORA_DE_FAIXA');
  end if;

  if v_hab is null then
    return jsonb_build_object(
      'ok', false, 'reason', 'HABILIDADE_NAO_INFORMADA',
      'habilidades', app.onboarding_habilidades(p_tenant_id));
  end if;

  -- Devolve o rascunho aberto, ou clona do publicado. Nunca cria do zero: sem
  -- rascunho publicado de origem nao existe equipe, horario nem habilidade.
  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_CONFIGURACAO_PUBLICADA_DE_ORIGEM');
  end;

  select k.id into v_skill
    from app.skills k
   where k.tenant_id = p_tenant_id
     and k.configuration_draft_id = v_rascunho
     and k.status = 'ACTIVE'
     and lower(k.name) = lower(v_hab)
     and exists (
       select 1
         from app.member_skills ms
         join app.team_members m
           on m.tenant_id = ms.tenant_id
          and m.configuration_draft_id = ms.configuration_draft_id
          and m.id = ms.member_id
          and m.status = 'ACTIVE'
        where ms.tenant_id = k.tenant_id
          and ms.configuration_draft_id = k.configuration_draft_id
          and ms.skill_id = k.id
     )
   limit 1;

  if v_skill is null then
    return jsonb_build_object(
      'ok', false, 'reason', 'HABILIDADE_NAO_EXISTE_NESTE_SALAO',
      'habilidades', app.onboarding_habilidades(p_tenant_id));
  end if;

  if exists (
    select 1 from app.services s
     where s.tenant_id = p_tenant_id
       and s.configuration_draft_id = v_rascunho
       and s.status = 'ACTIVE'
       and lower(s.name) = lower(v_nome)
  ) then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_JA_EXISTE');
  end if;

  insert into app.services (
    tenant_id, configuration_draft_id, name, kind, base_price_minor,
    currency, bookable, status
  ) values (
    p_tenant_id, v_rascunho, v_nome, 'SIMPLE'::app.service_kind,
    case when p_preco_reais is null then null else round(p_preco_reais * 100)::integer end,
    'BRL', true, 'ACTIVE'::app.record_status
  )
  returning id into v_servico;

  insert into app.service_steps (
    tenant_id, configuration_draft_id, service_id, name, position,
    duration_minutes, minimum_duration_minutes, maximum_duration_minutes,
    kind, technical_category, customer_presence_required, releases_member
  ) values (
    p_tenant_id, v_rascunho, v_servico, 'Execução', 1,
    p_duracao_min, p_duracao_min, p_duracao_min,
    'ACTIVE'::app.step_kind, 'OTHER'::app.technical_step_category, true, false
  )
  returning id into v_passo;

  insert into app.service_step_skill_requirements (
    tenant_id, configuration_draft_id, step_id, skill_id, quantity
  ) values (
    p_tenant_id, v_rascunho, v_passo, v_skill, 1
  );

  return jsonb_build_object(
    'ok', true,
    'servicoId', v_servico,
    'rascunho', v_rascunho,
    -- O desfazer de uma criacao e desativar, nao apagar: linha apagada leva
    -- junto qualquer coisa que ja tenha apontado para ela.
    'antes', jsonb_build_object('servicoCriado', v_servico)
  );
end;
$fn$;

comment on function app.onboarding_criar_servico(uuid, text, text, integer, numeric) is
  'Cria servico + passo + exigencia de habilidade no rascunho, de uma vez. A habilidade vem da lista fechada de app.onboarding_habilidades. Nada disso vale para cliente nenhuma ate o dono publicar.';

revoke all on function app.onboarding_criar_servico(uuid, text, text, integer, numeric) from public, anon, authenticated;
grant execute on function app.onboarding_criar_servico(uuid, text, text, integer, numeric) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Desativar servico. O caminho de volta da criacao.
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_desativar_servico(p_tenant_id uuid, p_service_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_alvo  uuid;
  v_nome  text;
begin
  v_alvo := app.servico_no_rascunho(p_tenant_id, p_service_id);
  if v_alvo is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO_NO_RASCUNHO');
  end if;

  update app.services
     set status = 'INACTIVE'::app.record_status,
         bookable = false,
         updated_at = statement_timestamp()
   where id = v_alvo and tenant_id = p_tenant_id
  returning name into v_nome;

  return jsonb_build_object('ok', true, 'servico', v_nome,
                            'antes', jsonb_build_object('status', 'ACTIVE'));
end;
$fn$;

revoke all on function app.onboarding_desativar_servico(uuid, uuid) from public, anon, authenticated;
grant execute on function app.onboarding_desativar_servico(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 4. O que falta para publicar, em frase de gente.
--
-- private.configuration_readiness devolve codigo. site_publish_configuration so
-- grita CONFIGURATION_NOT_READY. Nenhum dos dois serve para o Eddy explicar ao
-- dono o que falta -- e "deu erro" e a pior resposta possivel para quem esta
-- esperando o proprio salao entrar no ar.
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_pendencias_de_publicacao(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
begin
  select d.id into v_rascunho
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
   order by d.revision desc
   limit 1;

  if v_rascunho is null then
    return jsonb_build_object('rascunhoAberto', false, 'pendencias', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'rascunhoAberto', true,
    'pendencias', coalesce((
      select jsonb_agg(jsonb_build_object(
        'codigo', r.code,
        'oQueFalta', case r.code
          when 'UNIT_TIMEZONE_MISSING'        then 'O fuso horario do salao esta invalido.'
          when 'OPERATING_HOURS_MISSING'      then 'Nenhum horario de funcionamento cadastrado.'
          when 'LATEST_END_MISSING'           then 'Tem dia com horario de funcionamento sem limite de ultimo atendimento.'
          when 'NO_ACTIVE_MEMBER'             then 'Nenhuma pessoa ativa na equipe.'
          when 'MEMBER_AVAILABILITY_INVALID'  then 'Tem gente na equipe com horario fixo e nenhuma faixa cadastrada: ' || coalesce(m.name, '(sem nome)') || '.'
          when 'NO_BOOKABLE_SERVICE'          then 'Nenhum servico ativo que possa ser agendado.'
          when 'SERVICE_HAS_NO_STEPS'         then 'O servico "' || coalesce(s.name, '(sem nome)') || '" nao tem nenhuma etapa, entao ninguem sabe quanto tempo ele leva.'
          when 'STEP_SKILL_QUALIFIER_MISSING' then 'A etapa "' || coalesce(st.name, '(sem nome)') || '" exige uma habilidade que pede especificacao, e ela nao foi dada.'
          when 'STEP_HAS_NO_QUALIFIED_MEMBER' then 'A etapa "' || coalesce(st.name, '(sem nome)') || '" nao tem ninguem ativo que saiba fazer.'
          when 'RESOURCE_CAPACITY_MISSING'    then 'A etapa "' || coalesce(st.name, '(sem nome)') || '" precisa de mais equipamento do que o salao tem ativo.'
          when 'FINAL_MESSAGE_MISSING'        then 'Falta a mensagem de fechamento do atendimento.'
          else r.code
        end
      ) order by r.code)
      from private.configuration_readiness(v_rascunho) r
      left join app.services s     on s.id  = r.entity_id and r.entity_type = 'service'
      left join app.service_steps st on st.id = r.entity_id and r.entity_type = 'service_step'
      left join app.team_members m on m.id  = r.entity_id and r.entity_type = 'team_member'
    ), '[]'::jsonb)
  );
end;
$fn$;

revoke all on function app.onboarding_pendencias_de_publicacao(uuid) from public, anon, authenticated;
grant execute on function app.onboarding_pendencias_de_publicacao(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 5. O resumo do que mudou. O dono confirma isto, nao um botao no escuro.
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_resumo_do_rascunho(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
  v_revisao  integer;
  v_pub      jsonb;
  v_desde    timestamptz;
begin
  select d.id, d.revision into v_rascunho, v_revisao
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
   order by d.revision desc
   limit 1;

  if v_rascunho is null then
    return jsonb_build_object('rascunhoAberto', false);
  end if;

  select cv.snapshot, cv.published_at into v_pub, v_desde
    from app.configuration_versions cv
   where cv.tenant_id = p_tenant_id
   order by cv.version_number desc
   limit 1;

  return jsonb_build_object(
    'rascunhoAberto', true,
    'revisao', v_revisao,
    'servicosNovos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nome', s.name,
               'precoReais', case when s.base_price_minor is null then null
                                  else round(s.base_price_minor / 100.0, 2) end)
             order by s.name)
        from app.services s
       where s.tenant_id = p_tenant_id
         and s.configuration_draft_id = v_rascunho
         and s.status = 'ACTIVE'
         and not exists (
           select 1 from jsonb_array_elements(coalesce(v_pub->'services', '[]'::jsonb)) p
            where lower(p->>'name') = lower(s.name)
         )
    ), '[]'::jsonb),
    'precosQueMudaram', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nome', s.name,
               'de', case when (p->>'base_price_minor') is null then null
                          else round((p->>'base_price_minor')::numeric / 100.0, 2) end,
               'para', case when s.base_price_minor is null then null
                            else round(s.base_price_minor / 100.0, 2) end)
             order by s.name)
        from app.services s
        join jsonb_array_elements(coalesce(v_pub->'services', '[]'::jsonb)) p
          on lower(p->>'name') = lower(s.name)
       where s.tenant_id = p_tenant_id
         and s.configuration_draft_id = v_rascunho
         and s.status = 'ACTIVE'
         and coalesce(s.base_price_minor, -1) <> coalesce((p->>'base_price_minor')::integer, -1)
    ), '[]'::jsonb),
    'servicosDesativados', coalesce((
      select jsonb_agg(s.name order by s.name)
        from app.services s
       where s.tenant_id = p_tenant_id
         and s.configuration_draft_id = v_rascunho
         and s.status = 'INACTIVE'
    ), '[]'::jsonb),
    'regrasNovas', coalesce((
      select jsonb_agg(jsonb_build_object('assunto', ap.topic::text, 'titulo', ap.title)
             order by ap.created_at)
        from app.agent_policies ap
       where ap.tenant_id = p_tenant_id
         and ap.status = 'ACTIVE'
         and (v_desde is null or ap.created_at > v_desde)
    ), '[]'::jsonb)
  );
end;
$fn$;

revoke all on function app.onboarding_resumo_do_rascunho(uuid) from public, anon, authenticated;
grant execute on function app.onboarding_resumo_do_rascunho(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 6. Publicar no comando do dono.
--
-- O Eddy e OPERATOR e continua NAO podendo publicar. Quem publica e o dono:
-- esta funcao so reconhece o numero de WhatsApp dele em app.owner_whatsapp,
-- pega o e-mail, e entrega o trabalho para public.site_publish_configuration --
-- que continua exigindo OWNER/ADMIN, revisao esperada e prontidao.
--
-- A frase que o dono escreveu fica gravada. "O dono mandou" tem que ser
-- verificavel depois, nao uma afirmacao da IA.
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_publicar(
  p_tenant_id    uuid,
  p_phone_digits text,
  p_confirmacao  text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_fone     text := regexp_replace(coalesce(p_phone_digits, ''), '[^0-9]', '', 'g');
  v_email    text;
  v_site     text;
  v_rascunho uuid;
  v_revisao  integer;
  v_pend     jsonb;
  v_res      jsonb;
begin
  if length(v_fone) < 8 then
    return jsonb_build_object('ok', false, 'reason', 'TELEFONE_INVALIDO');
  end if;

  if coalesce(trim(p_confirmacao), '') = '' or length(trim(p_confirmacao)) < 2 then
    return jsonb_build_object('ok', false, 'reason', 'SEM_CONFIRMACAO_DO_DONO');
  end if;

  select o.email_normalized into v_email
    from app.owner_whatsapp o
   where o.tenant_id = p_tenant_id
     and o.status = 'ACTIVE'
     and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8) = right(v_fone, 8)
   limit 1;

  if v_email is null then
    return jsonb_build_object('ok', false, 'reason', 'NAO_E_O_DONO');
  end if;

  select si.site_project_id into v_site
    from app.site_identities si
   where si.tenant_id = p_tenant_id
     and si.email_normalized = v_email
     and si.status = 'ACTIVE'
     and si.role in ('OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role)
   limit 1;

  if v_site is null then
    return jsonb_build_object('ok', false, 'reason', 'DONO_SEM_ACESSO_DE_DONO');
  end if;

  select d.id, d.revision into v_rascunho, v_revisao
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
   order by d.revision desc
   limit 1;

  if v_rascunho is null then
    return jsonb_build_object('ok', false, 'reason', 'NADA_PARA_PUBLICAR');
  end if;

  v_pend := app.onboarding_pendencias_de_publicacao(p_tenant_id);
  if jsonb_array_length(coalesce(v_pend->'pendencias', '[]'::jsonb)) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'FALTA_COISA',
                              'pendencias', v_pend->'pendencias');
  end if;

  -- A frase do dono entra no registro ANTES da publicacao: se a publicacao
  -- falhar, continua existindo prova de que ele pediu.
  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id,
    configuration_version_id, correlation_id, result, metadata_minimized
  ) values (
    p_tenant_id, 'SYSTEM', null, 'OWNER_PUBLISH_COMMAND', 'configuration_draft',
    v_rascunho, null, 'eddy-publica-' || v_rascunho::text, 'SUCCESS',
    jsonb_build_object(
      'canal', 'WHATSAPP',
      'telefoneUltimos4', right(v_fone, 4),
      'donoEmail', v_email,
      'palavrasDoDono', left(trim(p_confirmacao), 500),
      'revisao', v_revisao)
  );

  begin
    v_res := public.site_publish_configuration(
      v_site, v_email, p_tenant_id, v_revisao,
      'eddy-publica-' || v_rascunho::text);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'PUBLICACAO_RECUSADA',
                              'detalhe', left(sqlerrm, 300));
  end;

  return jsonb_build_object('ok', true, 'versao', v_res);
end;
$fn$;

comment on function app.onboarding_publicar(uuid, text, text) is
  'Publica a configuracao no comando do dono, reconhecido pelo numero de WhatsApp em app.owner_whatsapp. O Eddy nao tem autoridade propria: quem publica e site_publish_configuration com o e-mail do dono, e as travas de OWNER/ADMIN, revisao e prontidao continuam todas de pe.';

revoke all on function app.onboarding_publicar(uuid, text, text) from public, anon, authenticated;
grant execute on function app.onboarding_publicar(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 7. As portas no schema publico, que e por onde a Edge Function alcanca.
-- ---------------------------------------------------------------------------
create or replace function public.onboarding_habilidades(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $fn$ select app.onboarding_habilidades(p_tenant_id); $fn$;

create or replace function public.onboarding_criar_servico(
  p_tenant_id uuid, p_nome text, p_habilidade text,
  p_duracao_min integer, p_preco_reais numeric default null)
returns jsonb language sql security definer set search_path to ''
as $fn$ select app.onboarding_criar_servico(p_tenant_id, p_nome, p_habilidade, p_duracao_min, p_preco_reais); $fn$;

create or replace function public.onboarding_desativar_servico(p_tenant_id uuid, p_service_id uuid)
returns jsonb language sql security definer set search_path to ''
as $fn$ select app.onboarding_desativar_servico(p_tenant_id, p_service_id); $fn$;

create or replace function public.onboarding_pendencias_de_publicacao(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $fn$ select app.onboarding_pendencias_de_publicacao(p_tenant_id); $fn$;

create or replace function public.onboarding_resumo_do_rascunho(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $fn$ select app.onboarding_resumo_do_rascunho(p_tenant_id); $fn$;

create or replace function public.onboarding_publicar(p_tenant_id uuid, p_phone_digits text, p_confirmacao text)
returns jsonb language sql security definer set search_path to ''
as $fn$ select app.onboarding_publicar(p_tenant_id, p_phone_digits, p_confirmacao); $fn$;

revoke all on function public.onboarding_habilidades(uuid) from public, anon, authenticated;
revoke all on function public.onboarding_criar_servico(uuid, text, text, integer, numeric) from public, anon, authenticated;
revoke all on function public.onboarding_desativar_servico(uuid, uuid) from public, anon, authenticated;
revoke all on function public.onboarding_pendencias_de_publicacao(uuid) from public, anon, authenticated;
revoke all on function public.onboarding_resumo_do_rascunho(uuid) from public, anon, authenticated;
revoke all on function public.onboarding_publicar(uuid, text, text) from public, anon, authenticated;

grant execute on function public.onboarding_habilidades(uuid) to service_role;
grant execute on function public.onboarding_criar_servico(uuid, text, text, integer, numeric) to service_role;
grant execute on function public.onboarding_desativar_servico(uuid, uuid) to service_role;
grant execute on function public.onboarding_pendencias_de_publicacao(uuid) to service_role;
grant execute on function public.onboarding_resumo_do_rascunho(uuid) to service_role;
grant execute on function public.onboarding_publicar(uuid, text, text) to service_role;

notify pgrst, 'reload schema';
