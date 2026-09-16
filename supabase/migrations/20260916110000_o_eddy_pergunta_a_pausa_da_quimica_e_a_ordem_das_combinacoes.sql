-- O EDDY PERGUNTA A PAUSA DA QUIMICA E A ORDEM DAS COMBINACOES.
--
-- A varredura de ontem achou o buraco, e ele nao esta no prompt: esta no
-- catalogo. O salao inteiro funciona em ondas -- "durante a pausa quimica de
-- uma, o profissional atende outra", 8,5 atendimentos por dia em 4 cadeiras --
-- e o cadastro nao sabe disso:
--
--   Mechas morena iluminada .... 240 min, UMA etapa, nenhuma pausa
--   Mechas loiras .............. 300 min, UMA etapa, nenhuma pausa
--   Progressiva com formol ..... 145 min, nenhuma pausa
--   Selante com formol ......... 105 min, nenhuma pausa
--
-- E onde a pausa existe, ela nao libera ninguem: das 42 etapas de pausa do
-- salao, 14 liberam o profissional. As outras 28 seguram a pessoa parada ao
-- lado de uma cliente que esta esperando produto agir.
--
-- Efeito no dinheiro: a agenda diz "lotado" quando nao esta, e o agente recusa
-- horario que existe. Nao da para eu inventar esses minutos -- eles sao do
-- William. Entao viram pergunta do Eddy.
--
-- E AQUI APARECEU O BLOQUEIO QUE NINGUEM TINHA VISTO. O Eddy escreve no
-- RASCUNHO, e as quatro configuracoes deste salao estao PUBLISHED: nao existe
-- rascunho aberto. A pendencia de preco exige rascunho para aparecer, entao
-- ela nunca aparecia, e a escrita de preco responderia
-- SERVICO_NAO_ESTA_NO_RASCUNHO_DESTE_SALAO. O Eddy nao conseguiria gravar NADA
-- hoje, e isso estava silencioso desde que ele nasceu.
--
-- A clonagem de rascunho ja existia, mas trancada dentro de
-- `site_start_new_draft`, que exige sessao do site. Aqui ela sai para uma
-- funcao interna que os dois caminhos usam: a tela continua igual, e o Eddy
-- ganha a mesma porta.

-- ---------------------------------------------------------------------------
-- 1. A clonagem deixa de ser exclusiva da tela.
-- ---------------------------------------------------------------------------
create or replace function app.start_new_draft_from_published(
  p_tenant_id uuid,
  p_actor text default 'eddy@whatsapp',
  p_correlation_id text default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  source_draft app.configuration_drafts%rowtype;
  existing_open_draft app.configuration_drafts%rowtype;
  new_draft_id uuid;
  next_revision integer;
  skill_map jsonb := '{}'::jsonb;
  qualifier_option_map jsonb := '{}'::jsonb;
  member_map jsonb := '{}'::jsonb;
  resource_type_map jsonb := '{}'::jsonb;
  service_map jsonb := '{}'::jsonb;
  step_map jsonb := '{}'::jsonb;
  rec record;
  new_id uuid;
begin
  -- Rascunho aberto e rascunho aberto: nao se clona por cima.
  select d.* into existing_open_draft
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
   order by d.revision desc
   limit 1;

  if existing_open_draft.id is not null then
    return existing_open_draft.id;
  end if;

  select d.* into source_draft
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'PUBLISHED'
   order by d.revision desc
   limit 1
   for update;

  if source_draft.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_PUBLISHED_DRAFT_NOT_FOUND';
  end if;

  select coalesce(max(d.revision), 0) + 1 into next_revision
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.unit_id = source_draft.unit_id;

  insert into app.configuration_drafts (
    tenant_id, unit_id, revision, status, deposit_enabled, channel_mode, final_message_template,
    cancellation_policy_enabled, cancellation_window_hours, cancellation_charge_type,
    cancellation_charge_amount_minor, cancellation_charge_percentage
  ) values (
    source_draft.tenant_id, source_draft.unit_id, next_revision, 'DRAFT',
    source_draft.deposit_enabled, source_draft.channel_mode, source_draft.final_message_template,
    source_draft.cancellation_policy_enabled, source_draft.cancellation_window_hours,
    source_draft.cancellation_charge_type, source_draft.cancellation_charge_amount_minor,
    source_draft.cancellation_charge_percentage
  )
  returning id into new_draft_id;

  for rec in select * from app.skills where configuration_draft_id = source_draft.id
  loop
    insert into app.skills (tenant_id, configuration_draft_id, name, status, qualifier_label, qualifier_allow_custom)
    values (rec.tenant_id, new_draft_id, rec.name, rec.status, rec.qualifier_label, rec.qualifier_allow_custom)
    returning id into new_id;
    skill_map := skill_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.skill_qualifier_options where configuration_draft_id = source_draft.id
  loop
    insert into app.skill_qualifier_options (tenant_id, configuration_draft_id, skill_id, label, position)
    values (rec.tenant_id, new_draft_id, (skill_map ->> rec.skill_id::text)::uuid, rec.label, rec.position)
    returning id into new_id;
    qualifier_option_map := qualifier_option_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.team_members where configuration_draft_id = source_draft.id
  loop
    insert into app.team_members (tenant_id, configuration_draft_id, name, member_type, availability_mode, status)
    values (rec.tenant_id, new_draft_id, rec.name, rec.member_type, rec.availability_mode, rec.status)
    returning id into new_id;
    member_map := member_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.member_skills where configuration_draft_id = source_draft.id
  loop
    insert into app.member_skills (tenant_id, configuration_draft_id, member_id, skill_id, priority)
    values (
      rec.tenant_id, new_draft_id,
      (member_map ->> rec.member_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      rec.priority
    );
  end loop;

  for rec in select * from app.member_skill_qualifiers where configuration_draft_id = source_draft.id
  loop
    insert into app.member_skill_qualifiers (tenant_id, configuration_draft_id, member_id, skill_id, qualifier_option_id, custom_value)
    values (
      rec.tenant_id, new_draft_id,
      (member_map ->> rec.member_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      case when rec.qualifier_option_id is null then null else (qualifier_option_map ->> rec.qualifier_option_id::text)::uuid end,
      rec.custom_value
    );
  end loop;

  for rec in select * from app.member_availability where configuration_draft_id = source_draft.id
  loop
    insert into app.member_availability (tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at)
    values (rec.tenant_id, new_draft_id, (member_map ->> rec.member_id::text)::uuid, rec.weekday, rec.starts_at, rec.ends_at);
  end loop;

  for rec in select * from app.member_dynamic_shifts where configuration_draft_id = source_draft.id
  loop
    insert into app.member_dynamic_shifts (tenant_id, configuration_draft_id, member_id, shift_date, starts_at, ends_at)
    values (rec.tenant_id, new_draft_id, (member_map ->> rec.member_id::text)::uuid, rec.shift_date, rec.starts_at, rec.ends_at);
  end loop;

  for rec in select * from app.resource_types where configuration_draft_id = source_draft.id
  loop
    insert into app.resource_types (tenant_id, configuration_draft_id, name, description)
    values (rec.tenant_id, new_draft_id, rec.name, rec.description)
    returning id into new_id;
    resource_type_map := resource_type_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.resources where configuration_draft_id = source_draft.id
  loop
    insert into app.resources (tenant_id, configuration_draft_id, resource_type_id, name, capacity, status)
    values (
      rec.tenant_id, new_draft_id,
      (resource_type_map ->> rec.resource_type_id::text)::uuid,
      rec.name, rec.capacity, rec.status
    );
  end loop;

  for rec in select * from app.services where configuration_draft_id = source_draft.id
  loop
    insert into app.services (
      tenant_id, configuration_draft_id, name, description, kind, base_price_minor, currency, bookable, status,
      requires_strand_test, strand_test_lead_days, strand_test_duration_minutes, strand_test_preferred_weekdays
    )
    values (
      rec.tenant_id, new_draft_id, rec.name, rec.description, rec.kind, rec.base_price_minor, rec.currency,
      rec.bookable, rec.status, rec.requires_strand_test, rec.strand_test_lead_days,
      rec.strand_test_duration_minutes, rec.strand_test_preferred_weekdays
    )
    returning id into new_id;
    service_map := service_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.service_variations where configuration_draft_id = source_draft.id
  loop
    insert into app.service_variations (tenant_id, configuration_draft_id, service_id, name, classification_values, price_minor, status)
    values (
      rec.tenant_id, new_draft_id, (service_map ->> rec.service_id::text)::uuid,
      rec.name, rec.classification_values, rec.price_minor, rec.status
    );
  end loop;

  for rec in select * from app.service_steps where configuration_draft_id = source_draft.id
  loop
    insert into app.service_steps (
      tenant_id, configuration_draft_id, service_id, name, position, duration_minutes, kind,
      customer_presence_required, releases_member,
      minimum_duration_minutes, maximum_duration_minutes
    )
    values (
      rec.tenant_id, new_draft_id, (service_map ->> rec.service_id::text)::uuid, rec.name, rec.position,
      rec.duration_minutes, rec.kind, rec.customer_presence_required, rec.releases_member,
      coalesce(rec.minimum_duration_minutes, rec.duration_minutes),
      coalesce(rec.maximum_duration_minutes, rec.duration_minutes)
    )
    returning id into new_id;
    step_map := step_map || jsonb_build_object(rec.id::text, new_id::text);
  end loop;

  for rec in select * from app.service_step_skill_requirements where configuration_draft_id = source_draft.id
  loop
    insert into app.service_step_skill_requirements (tenant_id, configuration_draft_id, step_id, skill_id, quantity)
    values (
      rec.tenant_id, new_draft_id,
      (step_map ->> rec.step_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      rec.quantity
    );
  end loop;

  for rec in select * from app.service_step_skill_qualifiers where configuration_draft_id = source_draft.id
  loop
    insert into app.service_step_skill_qualifiers (tenant_id, configuration_draft_id, step_id, skill_id, qualifier_option_id, custom_value)
    values (
      rec.tenant_id, new_draft_id,
      (step_map ->> rec.step_id::text)::uuid,
      (skill_map ->> rec.skill_id::text)::uuid,
      case when rec.qualifier_option_id is null then null else (qualifier_option_map ->> rec.qualifier_option_id::text)::uuid end,
      rec.custom_value
    );
  end loop;

  for rec in select * from app.service_step_resource_requirements where configuration_draft_id = source_draft.id
  loop
    insert into app.service_step_resource_requirements (tenant_id, configuration_draft_id, step_id, resource_type_id, quantity, retain_until_service_end)
    values (
      rec.tenant_id, new_draft_id,
      (step_map ->> rec.step_id::text)::uuid,
      (resource_type_map ->> rec.resource_type_id::text)::uuid,
      rec.quantity, rec.retain_until_service_end
    );
  end loop;

  for rec in select * from app.operating_hours where configuration_draft_id = source_draft.id
  loop
    insert into app.operating_hours (tenant_id, configuration_draft_id, weekday, starts_at, ends_at)
    values (rec.tenant_id, new_draft_id, rec.weekday, rec.starts_at, rec.ends_at);
  end loop;

  for rec in select * from app.unit_service_limits where configuration_draft_id = source_draft.id
  loop
    insert into app.unit_service_limits (tenant_id, configuration_draft_id, weekday, latest_end_time)
    values (rec.tenant_id, new_draft_id, rec.weekday, rec.latest_end_time);
  end loop;

  for rec in select * from app.client_schedule_exceptions where configuration_draft_id = source_draft.id
  loop
    insert into app.client_schedule_exceptions (tenant_id, configuration_draft_id, client_name, client_phone_digits, weekday, starts_at, ends_at, note)
    values (rec.tenant_id, new_draft_id, rec.client_name, rec.client_phone_digits, rec.weekday, rec.starts_at, rec.ends_at, rec.note);
  end loop;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, configuration_version_id,
    correlation_id, result, metadata_minimized
  ) values (
    p_tenant_id, 'USER', null, 'CONFIGURATION_DRAFT_STARTED', 'configuration_draft', new_draft_id,
    null, coalesce(p_correlation_id, 'draft-' || new_draft_id::text), 'SUCCESS',
    jsonb_build_object('sourceDraftId', source_draft.id, 'actorEmail', lower(trim(p_actor)))
  );

  return new_draft_id;
end;
$function$;

revoke all on function app.start_new_draft_from_published(uuid, text, text) from public, anon, authenticated;

-- A tela passa a usar a mesma porta. A permissao continua onde estava.
create or replace function public.site_start_new_draft(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_correlation_id text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  if target_correlation_id is null or length(target_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  perform app.start_new_draft_from_published(target_tenant_id, target_email, target_correlation_id);

  return public.site_load_configuration(target_site_project_id, target_email, target_tenant_id);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. As perguntas novas do Eddy.
--
-- `config` e a configuracao vigente: o rascunho aberto se existir, senao a
-- ultima publicada. Antes, a pendencia de preco so olhava rascunho -- entao
-- com tudo publicado ela nunca aparecia, e o Eddy ficava mudo sobre preco sem
-- ninguem saber. Agora ele pergunta sobre o que esta no ar, e a escrita abre o
-- rascunho quando precisa.
--
-- `respondidas` existe porque "nao tem pausa" tambem e resposta: sem isso o
-- Eddy perguntaria a mesma coisa para sempre, ja que nao ha o que gravar.
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_pendencies(p_tenant_id uuid)
returns table(modulo text, chave text, pergunta text, contexto text, prioridade integer)
language sql
stable
security definer
set search_path to ''
as $function$
  with config as (
    select coalesce(
      (select d.id from app.configuration_drafts d
        where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
        order by d.revision desc limit 1),
      (select d.id from app.configuration_drafts d
        where d.tenant_id = p_tenant_id and d.status = 'PUBLISHED'
        order by d.revision desc limit 1)
    ) as id
  ),
  respondidas as (
    select distinct a.pendency_key
      from app.onboarding_answers a
     where a.tenant_id = p_tenant_id and a.status = 'APLICADO'
  ),
  servicos as (
    select s.id, s.name,
           coalesce((select sum(st.duration_minutes) from app.service_steps st where st.service_id = s.id), 0) as minutos,
           (select count(*) from app.service_steps st where st.service_id = s.id and st.kind = 'PASSIVE') as pausas,
           (select count(*) from app.service_steps st where st.service_id = s.id and st.kind = 'PASSIVE' and st.releases_member) as pausas_que_liberam,
           (select coalesce(sum(st.duration_minutes), 0) from app.service_steps st where st.service_id = s.id and st.kind = 'PASSIVE') as minutos_de_pausa,
           (select count(*) from app.service_steps st where st.service_id = s.id) as etapas,
           (select count(*) from app.service_steps st where st.service_id = s.id and st.name ilike 'aplica%') as aplicacoes
      from app.services s, config c
     where s.tenant_id = p_tenant_id
       and s.configuration_draft_id = c.id
       and s.status = 'ACTIVE'
  )

  select 'SERVICOS'::text,
         'SERVICO_PRECO:' || s.id::text,
         'Quanto custa ' || s.name || '?',
         'Serviço ativo no catálogo, sem preço no cadastro nem nas variações.',
         10
    from app.services s, config c
   where s.tenant_id = p_tenant_id
     and s.configuration_draft_id = c.id
     and s.status = 'ACTIVE'
     and s.base_price_minor is null
     and not exists (
       select 1 from app.service_variations v
        where v.service_id = s.id and v.price_minor is not null
     )

  union all

  -- A pausa que nao existe no cadastro.
  select 'AGENDA'::text,
         'SERVICO_PAUSA:' || s.id::text,
         'Em ' || s.name || ', tem pausa esperando o produto agir? Quantos minutos, e nessa pausa você consegue atender outra cliente?',
         'Hoje o sistema reserva ' || s.minutos || ' minutos seguidos com você preso nessa cliente. Se existe pausa e ela te libera, cabe outra cliente no meio.',
         15
    from servicos s
   where s.pausas = 0
     -- Quimica se reconhece pela etapa de aplicacao de produto. O que nao tem
     -- essa etapa e vira uma bloco unico de duas horas ou mais tambem entra:
     -- e o caso das mechas, cadastradas como uma etapa so de 240 a 360 min.
     -- Corte, penteado e maquiagem ficam de fora, que e o certo -- ninguem
     -- espera produto agir num corte.
     and (s.aplicacoes > 0 or (s.etapas = 1 and s.minutos >= 120))
     and ('SERVICO_PAUSA:' || s.id::text) not in (select pendency_key from respondidas)

  union all

  -- A pausa que existe mas prende o profissional do mesmo jeito.
  select 'AGENDA'::text,
         'SERVICO_PAUSA_LIBERA:' || s.id::text,
         'Na pausa de ' || s.name || ', de ' || s.minutos_de_pausa || ' minutos, você consegue atender outra cliente ou precisa ficar com ela?',
         'A pausa está cadastrada, mas marcada como se você tivesse que ficar parado ao lado. Se te libera, dá para encaixar outra cliente.',
         16
    from servicos s
   where s.pausas > 0
     and s.pausas_que_liberam = 0
     and ('SERVICO_PAUSA_LIBERA:' || s.id::text) not in (select pendency_key from respondidas)

  union all

  select 'COR'::text,
         'COR_RESPOSTA:' || p.key,
         p.question,
         case when p.helper is null then 'Sem resposta; o sistema está usando a sugestão ' || p.suggested_value
              else p.helper || ' Hoje o sistema usa a sugestão ' || p.suggested_value || '.' end,
         20
    from app.color_policies p
   where p.tenant_id = p_tenant_id and p.answer_value is null

  union all

  -- A ordem e o intervalo entre duas quimicas que as clientes pedem juntas.
  -- So pergunta o par cujos DOIS serviços existem no catalogo deste salao e
  -- sobre o qual ainda nao ha regra escrita.
  select 'REGRAS'::text,
         'COMBINACAO:' || t.chave,
         'Quando a cliente quer ' || t.rotulo || ', o que vem primeiro e quanto tempo depois vem o segundo?',
         'Sem essa ordem escrita, o agente recusa fazer os dois no mesmo dia e depois chuta qual vem antes.',
         25
    from (values
      ('coloracao-corte',        'coloração e corte',        'Coloração',  'Corte'),
      ('coloracao-progressiva',  'coloração e progressiva',  'Coloração',  'Progressiva'),
      ('botox-progressiva',      'botox e progressiva',      'Botox',      'Progressiva'),
      ('selante-coloracao',      'selante e coloração',      'Selante',    'Coloração'),
      ('mechas-selante',         'mechas e selante',         'Mechas',     'Selante'),
      ('hidratacao-quimica',     'hidratação e química',     'Hidratação', 'Progressiva')
    ) as t(chave, rotulo, servico_a, servico_b)
   where exists (select 1 from servicos s where s.name ilike t.servico_a || '%')
     and exists (select 1 from servicos s where s.name ilike t.servico_b || '%')
     and ('COMBINACAO:' || t.chave) not in (select pendency_key from respondidas)
     -- So conta como respondida a regra de PROCEDIMENTO. Sem esse recorte, a
     -- regra de pos-atendimento -- que pergunta "deu tudo certo com a coloração
     -- e o corte?" -- fazia o par coloracao+corte parecer ja escrito.
     and not exists (
       select 1 from app.agent_policies ap
        where ap.tenant_id = p_tenant_id and ap.status = 'ACTIVE'
          and ap.topic = 'PROCEDIMENTO'
          and ap.body ilike '%' || t.servico_a || '%'
          and ap.body ilike '%' || t.servico_b || '%'
     )

  union all

  select 'COR'::text,
         'COR_FOTO_FAMILIA:' || f.id::text,
         'Mande uma foto de um cabelo que você chama de ' || f.name || '.',
         'A família existe mas não tem foto, então o sistema não aprendeu o que este salão chama assim.',
         30
    from app.tone_families f
   where f.tenant_id = p_tenant_id and f.status = 'ACTIVE'
     and not exists (select 1 from app.tone_family_photos ph where ph.family_id = f.id)

  union all

  select 'CONHECIMENTO'::text,
         'CONHECIMENTO_DESCRICAO:' || o.id::text,
         'Em ' || d.name || ', o que é ' || o.label || ' para você?',
         'A definição de hoje veio do padrão do sistema: ' || coalesce(o.description, 'sem definição'),
         40
    from app.knowledge_options o
    join app.knowledge_dimensions d on d.id = o.dimension_id
   where o.tenant_id = p_tenant_id and o.status = 'ACTIVE' and o.origin = 'PRODUTO'

  union all

  select 'REGRAS'::text,
         'REGRA:' || t.topico,
         t.pergunta,
         'Nenhuma regra escrita sobre isso. Sem ela, o agente para e te pergunta no meio do atendimento.',
         50
    from (values
      ('PAGAMENTO',   'Que formas de pagamento o salão aceita, e parcela em quantas vezes?'),
      ('CANCELAMENTO','O que acontece quando a cliente desmarca em cima da hora ou não aparece?'),
      ('ATRASO',      'Quanto tempo de atraso você ainda atende, e o que acontece depois disso?'),
      ('SINAL',       'Algum serviço exige sinal para segurar o horário? Qual e quanto?')
    ) as t(topico, pergunta)
   where not exists (
     select 1 from app.agent_policies ap
      where ap.tenant_id = p_tenant_id and ap.status = 'ACTIVE' and ap.topic::text = t.topico
   )

  order by 5, 3;
$function$;

revoke all on function app.onboarding_pendencies(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. O mesmo servico, do outro lado: no rascunho.
--
-- A pendencia aponta para o servico que esta NO AR; a escrita tem que cair no
-- RASCUNHO, que e outra linha com outro id. O que atravessa os dois e o nome.
-- Se nao houver rascunho, ele nasce aqui -- clonado do publicado, sem tocar em
-- nada que a cliente ve.
-- ---------------------------------------------------------------------------
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
    -- Zero e resposta legitima: "nao tem pausa". Nao escreve nada, e a
    -- pergunta para de aparecer porque a resposta fica registrada.
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

    -- "consigo atender outra", "libera", "sim": a pausa devolve o profissional.
    v_libera := coalesce(p_valor_texto, '') ~* '(consigo|dá para|da para|libera|atendo|sim|outra cliente|posso)';

    -- A pausa mora depois da aplicacao do produto, quando essa etapa existe;
    -- senao vai para o fim. O dono corrige a posicao na tela se precisar.
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
    -- Combinacao SEMPRE nasce como regra nova. Sobrescrever a primeira regra
    -- de PROCEDIMENTO -- que e o que o caminho 'REGRA' faz -- apagaria a ordem
    -- de luzes com progressiva que ja esta escrita.
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

    -- Topico que ja tem regra escrita ganha OUTRA regra, nao um por cima.
    -- Antes isto sobrescrevia a primeira regra ativa do assunto, e quem tinha
    -- duas regras de PROCEDIMENTO perdia uma sem aviso.
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
