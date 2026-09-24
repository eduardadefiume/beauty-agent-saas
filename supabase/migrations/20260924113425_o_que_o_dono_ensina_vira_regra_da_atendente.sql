-- O QUE O DONO ENSINA VIRA REGRA DA ATENDENTE.
--
-- 24/09/2026. A dona mandou a foto de um corte pixie e escreveu "nao faco esse
-- tipo de corte". O Eddy guardou em conhecimento_nao_classificado -- e parou
-- ali. A atendente le `agent_policies` com status ACTIVE e nada mais, entao uma
-- cliente que pedisse pixie ia ser atendida como se o salao fizesse.
--
-- O caminho novo: o Eddy escreve a regra em `agent_policies` como RASCUNHO, e a
-- publicacao do dono poe no ar. Nenhuma regra dele vale para cliente antes do
-- dono confirmar.
--
-- POR QUE UMA MARCA PROPRIA, E NAO SO status = 'DRAFT'. Na tela /agente, DRAFT
-- ja existe e quer dizer "rascunho, ele ignora": e como o dono DESLIGA uma
-- regra sem apagar. Promover todo DRAFT na publicacao religaria justamente o
-- que ele desligou de proposito. Entao a regra que o Eddy propoe nasce DRAFT
-- com `aguarda_publicacao = true`, e so essas sao promovidas.

-- ---------------------------------------------------------------------------
-- 1. A MARCA
-- ---------------------------------------------------------------------------
alter table app.agent_policies
  add column if not exists aguarda_publicacao boolean not null default false;

comment on column app.agent_policies.aguarda_publicacao is
  'true = regra proposta pelo Eddy, em rascunho, que entra no ar na proxima publicacao do dono. DRAFT sem esta marca e regra que o dono desligou na tela, e publicar nao mexe nela.';

-- Qualquer saida do DRAFT (dono ativou ou arquivou na tela) encerra a espera.
create or replace function app.agent_policies_encerra_espera()
returns trigger
language plpgsql
set search_path to ''
as $fn$
begin
  if new.status <> 'DRAFT' then
    new.aguarda_publicacao := false;
  end if;
  return new;
end;
$fn$;

drop trigger if exists agent_policies_encerra_espera on app.agent_policies;
create trigger agent_policies_encerra_espera
  before insert or update on app.agent_policies
  for each row execute function app.agent_policies_encerra_espera();

-- ---------------------------------------------------------------------------
-- 2. A MAO DO EDDY
-- ---------------------------------------------------------------------------
create or replace function app.eddy_criar_regra(
  p_tenant_id       uuid,
  p_assunto         text,
  p_titulo          text,
  p_regra           text,
  p_palavras        text default null,
  p_conversation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_topic  app.policy_topic;
  v_titulo text := trim(coalesce(p_titulo, ''));
  v_regra  text := trim(coalesce(p_regra, ''));
  v_linha  app.agent_policies;
  v_existia boolean;
begin
  if not exists (select 1 from app.tenants t where t.id = p_tenant_id) then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_NAO_EXISTE');
  end if;

  begin
    v_topic := p_assunto::app.policy_topic;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'ASSUNTO_INVALIDO');
  end;

  if length(v_titulo) < 2 or length(v_titulo) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'TITULO_INVALIDO');
  end if;
  if length(v_regra) < 5 then
    return jsonb_build_object('ok', false, 'reason', 'REGRA_VAZIA');
  end if;
  if length(v_regra) > 2000 then
    return jsonb_build_object('ok', false, 'reason', 'REGRA_LONGA_DEMAIS');
  end if;

  select * into v_linha
    from app.agent_policies ap
   where ap.tenant_id = p_tenant_id and ap.topic = v_topic and ap.title = v_titulo
   for update;
  v_existia := found;

  if v_existia and v_linha.status = 'ACTIVE' then
    -- Regra no ar nao e reescrita por conversa: a atendente ja fala assim com
    -- as clientes, e trocar em silencio tiraria do dono a chance de conferir.
    return jsonb_build_object('ok', false, 'reason', 'REGRA_JA_ESTA_NO_AR',
                              'textoAtual', v_linha.body);
  end if;

  if v_existia then
    -- DRAFT (proposta anterior ou regra que ele desligou) ou ARCHIVED: a mesma
    -- linha volta como proposta. A chave unica (tenant, assunto, titulo) nao
    -- deixa existir uma segunda.
    update app.agent_policies
       set body = v_regra, status = 'DRAFT', aguarda_publicacao = true,
           updated_at = statement_timestamp()
     where id = v_linha.id;
  else
    insert into app.agent_policies
      (tenant_id, topic, title, body, status, position, aguarda_publicacao)
    values
      (p_tenant_id, v_topic, v_titulo, v_regra, 'DRAFT',
       coalesce((select max(position) + 1 from app.agent_policies where tenant_id = p_tenant_id), 1),
       true);
  end if;

  -- A frase do dono fica registrada junto, ja marcada como promovida: e a
  -- procedencia da regra, com as palavras dele.
  if length(trim(coalesce(p_palavras, ''))) >= 5 then
    insert into app.conhecimento_nao_classificado
      (tenant_id, conversation_id, palavras_do_dono, palpite_modulo, palpite_escopo,
       porque_nao_coube, status, revisado_por, revisado_em)
    values
      (p_tenant_id, p_conversation_id, left(trim(p_palavras), 4000), 'REGRAS', 'DESTE_NEGOCIO',
       'Virou regra da atendente: ' || v_titulo, 'VIROU_REGRA', 'EDDY', statement_timestamp());
  end if;

  return jsonb_build_object('ok', true, 'assunto', v_topic::text, 'titulo', v_titulo,
                            'substituiuProposta', v_existia);
end;
$fn$;

revoke all on function app.eddy_criar_regra(uuid, text, text, text, text, uuid) from public, anon, authenticated;

create or replace function public.eddy_criar_regra(
  p_tenant_id uuid, p_assunto text, p_titulo text, p_regra text,
  p_palavras text default null, p_conversation_id uuid default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_criar_regra(p_tenant_id, p_assunto, p_titulo, p_regra, p_palavras, p_conversation_id); $$;

revoke all on function public.eddy_criar_regra(uuid, text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.eddy_criar_regra(uuid, text, text, text, text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 3. PUBLICAR POE NO AR -- PELA TELA OU PELO EDDY
-- ---------------------------------------------------------------------------
-- Um gatilho na versao publicada, e nao uma linha dentro de uma das funcoes de
-- publicar: a tela publica por site_publish_configuration e o Eddy tambem
-- chega nela. Os dois caminhos passam por aqui.
create or replace function app.publicar_regras_que_aguardam()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  update app.agent_policies
     set status = 'ACTIVE', aguarda_publicacao = false, updated_at = statement_timestamp()
   where tenant_id = new.tenant_id
     and status = 'DRAFT'
     and aguarda_publicacao;
  return new;
end;
$fn$;

revoke all on function app.publicar_regras_que_aguardam() from public, anon, authenticated;

drop trigger if exists publicar_regras_que_aguardam on app.configuration_versions;
create trigger publicar_regras_que_aguardam
  after insert on app.configuration_versions
  for each row execute function app.publicar_regras_que_aguardam();

-- Quando so mudou regra, nao ha rascunho de configuracao aberto, e a
-- publicacao respondia NADA_PARA_PUBLICAR: a regra ficaria esperando para
-- sempre. Mesmas travas de dono de antes; muda so o ramo sem rascunho.
create or replace function app.onboarding_publicar(p_tenant_id uuid, p_phone_digits text, p_confirmacao text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_fone     text := regexp_replace(coalesce(p_phone_digits, ''), '[^0-9]', '', 'g');
  v_email    text;
  v_site     text;
  v_rascunho uuid;
  v_revisao  integer;
  v_pend     jsonb;
  v_res      jsonb;
  v_regras   integer;
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
    select count(*) into v_regras
      from app.agent_policies ap
     where ap.tenant_id = p_tenant_id and ap.status = 'DRAFT' and ap.aguarda_publicacao;

    if v_regras = 0 then
      return jsonb_build_object('ok', false, 'reason', 'NADA_PARA_PUBLICAR');
    end if;

    insert into app.audit_logs (
      tenant_id, actor_type, actor_id, action, entity_type, entity_id,
      configuration_version_id, correlation_id, result, metadata_minimized
    ) values (
      p_tenant_id, 'SYSTEM', null, 'OWNER_PUBLISH_RULES_COMMAND', 'agent_policies',
      null, null, 'eddy-publica-regras-' || p_tenant_id::text, 'SUCCESS',
      jsonb_build_object(
        'canal', 'WHATSAPP',
        'telefoneUltimos4', right(v_fone, 4),
        'donoEmail', v_email,
        'palavrasDoDono', left(trim(p_confirmacao), 500),
        'regras', v_regras)
    );

    update app.agent_policies
       set status = 'ACTIVE', aguarda_publicacao = false, updated_at = statement_timestamp()
     where tenant_id = p_tenant_id and status = 'DRAFT' and aguarda_publicacao;

    return jsonb_build_object('ok', true, 'somenteRegras', true, 'regrasPublicadas', v_regras);
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
$function$;

-- ---------------------------------------------------------------------------
-- 4. O RESUMO MOSTRA A REGRA QUE VAI ENTRAR
-- ---------------------------------------------------------------------------
-- O Eddy so pode publicar depois de contar o resumo ao dono. Regra que nao
-- aparece no resumo seria publicada sem o dono ler.
create or replace function app.onboarding_resumo_do_rascunho(p_tenant_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_rascunho uuid;
  v_revisao  integer;
  v_pub      jsonb;
  v_desde    timestamptz;
  v_propostas jsonb;
begin
  v_propostas := coalesce((
    select jsonb_agg(jsonb_build_object('assunto', ap.topic::text, 'titulo', ap.title,
                                        'regra', ap.body)
           order by ap.updated_at)
      from app.agent_policies ap
     where ap.tenant_id = p_tenant_id and ap.status = 'DRAFT' and ap.aguarda_publicacao
  ), '[]'::jsonb);

  select d.id, d.revision into v_rascunho, v_revisao
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
   order by d.revision desc
   limit 1;

  if v_rascunho is null then
    return jsonb_build_object('rascunhoAberto', false,
                              'regrasParaPublicar', v_propostas);
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
    ), '[]'::jsonb),
    'regrasParaPublicar', v_propostas
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. O LEITOR DE MIDIA PRECISA SABER SE QUEM MANDOU E O DONO
-- ---------------------------------------------------------------------------
-- Foto de cliente se le como cabelo DELA. Foto do dono e aula: ele esta
-- mostrando uma tecnica, um corte, um resultado. A leitura tem que ser outra.
create or replace function public.mensagem_e_do_dono(p_message_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((
    select app.conversa_e_do_dono(m.conversation_id)
      from app.crm_messages m
     where m.id = p_message_id
  ), false);
$$;

revoke all on function public.mensagem_e_do_dono(uuid) from public, anon, authenticated;
grant execute on function public.mensagem_e_do_dono(uuid) to service_role;
