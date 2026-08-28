-- O dono escreve as próprias regras. Nenhuma delas mora em código.
--
-- A PREOCUPAÇÃO, e ela está certa. Ao consertar o agente eu ia escrevendo as
-- regras do William dentro do prompt: como falar do teste de mecha, que o valor
-- da morena iluminada quase não muda. Funciona para ele e transforma um SaaS em
-- um sistema sob medida. O segundo salão chega com outras regras e a única
-- forma de atendê-lo seria eu editar código de novo -- o que quer dizer que não
-- dá para vender.
--
-- ONDE ESTAVA A LINHA, ANTES DESTE ARQUIVO. Já eram dados: catálogo, preço,
-- duração, etapas, horário de funcionamento, equipe, ficha da cliente,
-- cadência, artes de promoção e a observação do dono sobre cada arte. Ainda
-- era código: tudo que o dono diria em palavras -- como ele fala, o que ele
-- explica sobre um procedimento, o que ele quer que nunca seja dito. Não havia
-- lugar nenhum onde uma frase escrita pela dona chegasse ao agente.
--
-- É esse lugar. `app.agent_policies`: o dono escreve, por assunto, do jeito
-- dele. O texto entra no bloco estável do contexto -- o mesmo que já carrega
-- catálogo e horário -- então é cacheado e não custa por mensagem.
--
-- A REGRA QUE DIVIDE CÓDIGO DE CONFIGURAÇÃO, daqui para a frente:
--   Em código, só o que é verdade em QUALQUER negócio de beleza. "Nunca diga
--   que vai verificar." "Regra escrita é resposta, não pergunta." "Não invente
--   preço." Isso é o produto.
--   Em dados, tudo que muda de salão para salão. Se a frase tem o nome de um
--   procedimento, um valor, um tom de voz ou um jeito de explicar, ela é do
--   dono e vai para cá.
--   Teste prático: se para atender o segundo cliente eu precisar reescrever a
--   frase, ela está no lugar errado.
--
-- POR QUE TEXTO LIVRE E NÃO CAMPOS ESTRUTURADOS. Campo estruturado só serve
-- para o que o motor calcula -- duração, preço, dia da semana. O que o dono
-- sabe sobre o próprio trabalho não cabe em caixinha: "cabelo com henna eu não
-- pego", "se ela vem de coloração de farmácia, teste obrigatório", "nunca
-- prometo loiro platinado em uma sessão". Estruturar isso seria adivinhar as
-- regras de um ofício que não é meu, e eu erraria em todos os salões que ainda
-- não conheço. O assunto é estruturado para a tela poder organizar; o conteúdo
-- é dele.

do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'policy_topic') then
    create type app.policy_topic as enum (
      'VOZ',            -- como falar: tratamento, tamanho da mensagem, o que nunca dizer
      'PRECO',          -- como falar de valor, reajuste, sinal
      'AVALIACAO',      -- teste de mecha, avaliação, o que explicar sobre eles
      'AGENDAMENTO',    -- como oferecer horário, encaixe, antecedência
      'PROCEDIMENTO',   -- o que este negócio faz e não faz, e por quê
      'PROMOCAO',       -- como tratar promoção e status
      'FOTOS',          -- o que pedir, o que guardar, o que nunca comentar
      'ATENDIMENTO',    -- atraso, falta, remarcação, reclamação
      'OUTRO'
    );
  end if;
end $$;

create table if not exists app.agent_policies (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references app.tenants(id) on delete cascade,

  topic      app.policy_topic not null,

  -- Um rótulo curto para a tela. Não vai para o agente como categoria: vai
  -- junto do texto, porque muitas vezes o título já é metade da regra.
  title      text not null check (length(trim(title)) between 2 and 120),

  -- O que o dono escreveu, com as palavras dele.
  body       text not null check (length(trim(body)) between 2 and 2000),

  status     text not null default 'ACTIVE' check (status in ('ACTIVE', 'DRAFT', 'ARCHIVED')),
  position   integer not null default 0,

  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),

  unique (tenant_id, topic, title)
);

create index if not exists agent_policies_ativas_idx
  on app.agent_policies (tenant_id, topic, position)
  where status = 'ACTIVE';

comment on table app.agent_policies is
  'As regras que o dono escreve com as proprias palavras, por assunto. Entram no bloco cacheado do contexto do agente. Nenhuma regra especifica de um salao deve existir no prompt -- se precisa ser reescrita para atender o segundo cliente, o lugar dela e aqui.';

-- O que o agente recebe. Ordem determinística: o bloco é cacheado e precisa
-- ser byte a byte igual entre conversas do mesmo salão.
create or replace function app.agent_policies_for_agent(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'assunto', p.topic,
           'titulo', p.title,
           'regra', p.body
         ) order by p.topic, p.position, p.title), '[]'::jsonb)
    from app.agent_policies p
   where p.tenant_id = p_tenant_id
     and p.status = 'ACTIVE';
$function$;

revoke all on function app.agent_policies_for_agent(uuid) from public, anon, authenticated;
grant execute on function app.agent_policies_for_agent(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- A tela do dono: ler, gravar, apagar.
-- ---------------------------------------------------------------------------
create or replace function public.site_load_agent_policies(
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
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return jsonb_build_object(
    -- A tela precisa saber quais assuntos existem sem ter a lista chumbada no
    -- JavaScript; assim, um assunto novo aparece sozinho.
    'topics', (select jsonb_agg(e.enumlabel order by e.enumsortorder)
                 from pg_enum e join pg_type t on t.oid = e.enumtypid
                 join pg_namespace n on n.oid = t.typnamespace
                where n.nspname = 'app' and t.typname = 'policy_topic'),
    'policies', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id,
               'topic', p.topic,
               'title', p.title,
               'body', p.body,
               'status', p.status,
               'position', p.position,
               'updatedAt', p.updated_at
             ) order by p.topic, p.position, p.title)
        from app.agent_policies p
       where p.tenant_id = target_tenant_id
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_load_agent_policies(text, text, uuid) to service_role;

create or replace function public.site_save_agent_policy(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_policy          jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id       uuid := nullif(target_policy->>'id', '')::uuid;
  v_topic    app.policy_topic;
  v_title    text := trim(coalesce(target_policy->>'title', ''));
  v_body     text := trim(coalesce(target_policy->>'body', ''));
  v_status   text := coalesce(nullif(target_policy->>'status', ''), 'ACTIVE');
  v_position integer := coalesce((target_policy->>'position')::integer, 0);
  v_linha    app.agent_policies;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  -- Assunto inválido vira erro nomeado, não estouro de cast: quem está do
  -- outro lado é uma tela, e uma tela merece saber o que fez de errado.
  begin
    v_topic := (target_policy->>'topic')::app.policy_topic;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'TOPIC_INVALID');
  end;

  if length(v_title) < 2 then return jsonb_build_object('ok', false, 'reason', 'TITLE_REQUIRED'); end if;
  if length(v_body)  < 2 then return jsonb_build_object('ok', false, 'reason', 'BODY_REQUIRED');  end if;
  if v_status not in ('ACTIVE', 'DRAFT', 'ARCHIVED') then
    return jsonb_build_object('ok', false, 'reason', 'STATUS_INVALID');
  end if;

  if v_id is null then
    insert into app.agent_policies (tenant_id, topic, title, body, status, position)
    values (target_tenant_id, v_topic, v_title, left(v_body, 2000), v_status, v_position)
    on conflict (tenant_id, topic, title) do update
      set body = excluded.body, status = excluded.status,
          position = excluded.position, updated_at = statement_timestamp()
    returning * into v_linha;
  else
    update app.agent_policies
       set topic = v_topic, title = v_title, body = left(v_body, 2000),
           status = v_status, position = v_position,
           updated_at = statement_timestamp()
     where tenant_id = target_tenant_id and id = v_id
    returning * into v_linha;

    if not found then
      return jsonb_build_object('ok', false, 'reason', 'POLICY_NOT_FOUND');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_linha.id, 'updatedAt', v_linha.updated_at);
end;
$function$;

grant execute on function public.site_save_agent_policy(text, text, uuid, jsonb) to service_role;

create or replace function public.site_delete_agent_policy(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_policy_id       uuid
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

  delete from app.agent_policies
   where tenant_id = target_tenant_id and id = target_policy_id;

  return jsonb_build_object('ok', found);
end;
$function$;

grant execute on function public.site_delete_agent_policy(text, text, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- As regras do William saem do meu prompt e viram dado dele.
--
-- Estas linhas são as palavras da dona nesta conversa e no briefing de voz,
-- não invenção minha. Ficam aqui como semente para o salão-piloto; qualquer
-- salão novo começa com esta tabela vazia e o dono escreve a dele.
-- ---------------------------------------------------------------------------
insert into app.agent_policies (tenant_id, topic, title, body, position)
select t.id, v.topic::app.policy_topic, v.title, v.body, v.position
  from app.tenants t
 cross join (values
   ('AVALIACAO', 'O que explicar sobre o teste de mecha',
    'O teste mostra a saúde do fio, quanto o cabelo aguenta e até que tom dá para chegar com segurança. Explique assim, com palavras simples, e ofereça o horário na mesma mensagem. O teste e o procedimento são marcados em dias separados.',
    1),
   ('AVALIACAO', 'Tranquilizar sobre o valor da avaliação',
    'Quando o caso for morena iluminada, o valor quase sempre fica no que está anunciado na promoção. Diga isso para a cliente ficar tranquila, sem prometer valor fechado.',
    2),
   ('PRECO', 'Preço de arte é ponto de partida',
    'O valor que aparece na arte é "a partir de". Cabelo mais longo e mais volumoso custa mais. Nunca feche um valor exato por mensagem antes de ver o cabelo.',
    1)
 ) as v(topic, title, body, position)
 -- Só o salão do William. A base já tem três tenants; semear "todos" seria
 -- justamente o erro que esta migração existe para evitar -- o Studio da Jack
 -- passaria a falar de morena iluminada sem nunca ter dito isso a ninguém.
 where t.slug = 'salao-do-william'
   and not exists (
     select 1 from app.agent_policies p
      where p.tenant_id = t.id and p.topic = v.topic::app.policy_topic and p.title = v.title
   );
