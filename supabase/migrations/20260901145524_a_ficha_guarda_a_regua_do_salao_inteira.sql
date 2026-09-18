-- A ficha passa a caber a régua inteira do salão -- e a guardar quem respondeu.
--
-- O BURACO. A ficha tinha duas gavetas fixas: `length_option_id` e
-- `thickness_option_id`. Só que a régua ("Comprimento: curto/longo") é cadastrada
-- pelo salão, na tela de Conhecimento, e não tem número fixo. No dia em que o
-- William criar "Volume" ou "Saúde do fio" -- e ele vai, porque é exatamente
-- isso que a tela oferece -- a resposta não teria onde ser gravada. A tela
-- deixaria cadastrar a pergunta e o sistema jogaria a resposta fora.
--
-- Espessura, aliás, já é prova disso: a coluna existe desde o começo e nunca
-- teve uma dimensão correspondente. É uma gaveta que ninguém consegue abrir.
--
-- O QUE MUDA. Uma linha por (ficha, dimensão). Quantas dimensões o salão criar,
-- tantas cabem. As duas colunas antigas continuam existindo e continuam sendo
-- espelhadas, porque muita coisa ainda lê delas -- mas a fonte de verdade passa
-- a ser esta tabela.
--
-- E TRÊS COISAS QUE A TABELA GRAVA E A COLUNA NÃO GRAVAVA:
--
--   1. QUEM RESPONDEU. Pessoa, agente lendo foto, agente ouvindo a conversa.
--      Sem isso não dá para cumprir a regra que a Duda pediu: o motor de foto
--      NUNCA sobrescreve o que uma pessoa respondeu à mão.
--   2. QUANTO ELE CONFIA. Uma classificação por foto com 0.55 de confiança não
--      é a mesma coisa que uma com 0.95, e tratá-las igual é o caminho mais
--      curto para o agente afirmar bobagem com segurança.
--   3. EM CIMA DE QUÊ. A mensagem que serviu de evidência. A foto não é
--      guardada (LGPD); o rastro de qual mensagem gerou a leitura, sim.

create table if not exists app.client_classifications (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  profile_id   uuid not null references app.client_profiles(id) on delete cascade,
  dimension_id uuid not null references app.knowledge_dimensions(id) on delete cascade,
  option_id    uuid not null references app.knowledge_options(id) on delete cascade,
  -- Nulo quando quem respondeu foi gente: pessoa não tem porcentagem de certeza.
  confidence   numeric(4,3) check (confidence is null or (confidence >= 0 and confidence <= 1)),
  source       text not null check (source in ('PESSOA', 'AGENTE_FOTO', 'AGENTE_CONVERSA')),
  decided_at   timestamptz not null default now(),
  evidence_message_id uuid references app.crm_messages(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (profile_id, dimension_id)
);

create index if not exists client_classifications_tenant_idx
  on app.client_classifications (tenant_id, profile_id);

alter table app.client_classifications enable row level security;

comment on table app.client_classifications is
  'Como esta cliente se encaixa na regua que ESTE salao cadastrou. Uma linha por (ficha, dimensao) -- quantas dimensoes o salao criar, tantas cabem. Guarda quem respondeu e quanto confia.';
comment on column app.client_classifications.source is
  'PESSOA (alguem respondeu na tela), AGENTE_FOTO (o motor leu uma foto), AGENTE_CONVERSA (a cliente contou por escrito). PESSOA nunca e sobrescrito por agente.';
comment on column app.client_classifications.confidence is
  'De 0 a 1, quanto o motor confia nesta leitura. Nulo quando quem respondeu foi gente.';
comment on column app.client_classifications.evidence_message_id is
  'Em cima de qual mensagem a leitura foi feita. A foto nao e guardada (LGPD) -- o rastro, sim.';

-- ---------------------------------------------------------------------------
-- O que já estava nas duas colunas antigas vira linha aqui, marcado como PESSOA.
--
-- Marcar como PESSOA é a leitura correta e a conservadora ao mesmo tempo: o que
-- está lá hoje foi digitado por alguém na tela de Clientes, e mesmo que não
-- tivesse sido, marcar assim impede que o motor de foto passe por cima de dado
-- que já existia sem ninguém ter conferido.
-- ---------------------------------------------------------------------------
insert into app.client_classifications
  (tenant_id, profile_id, dimension_id, option_id, source, decided_at)
select p.tenant_id, p.id, o.dimension_id, o.id, 'PESSOA', p.updated_at
  from app.client_profiles p
  join app.knowledge_options o on o.id = p.length_option_id
 where p.length_option_id is not null
on conflict (profile_id, dimension_id) do nothing;

insert into app.client_classifications
  (tenant_id, profile_id, dimension_id, option_id, source, decided_at)
select p.tenant_id, p.id, o.dimension_id, o.id, 'PESSOA', p.updated_at
  from app.client_profiles p
  join app.knowledge_options o on o.id = p.thickness_option_id
 where p.thickness_option_id is not null
on conflict (profile_id, dimension_id) do nothing;

-- ---------------------------------------------------------------------------
-- Gravar uma classificação, com a regra de quem pode passar por cima de quem.
--
-- A REGRA, que é da Duda e vale para o produto inteiro: "classificar com
-- confiança alta e perguntar no resto". Traduzida em código:
--
--   - Resposta de PESSOA é definitiva. Agente nenhum a sobrescreve.
--   - Agente abaixo do limite não grava NADA. Não grava um palpite fraco para
--     depois ninguém saber que era palpite: ele simplesmente não responde, a
--     dimensão continua na lista de pendências, e o agente pergunta.
--   - Agente acima do limite grava, junto com a confiança e a evidência.
--
-- O limite mora aqui, e não no worker, porque é decisão de produto e não de
-- infraestrutura: mudar de 0.75 para 0.85 não pode exigir um deploy.
-- ---------------------------------------------------------------------------
create or replace function app.set_client_classification(
  p_tenant_id    uuid,
  p_profile_id   uuid,
  p_dimension_id uuid,
  p_option_id    uuid,
  p_source       text,
  p_confidence   numeric default null,
  p_message_id   uuid default null
)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  -- Abaixo disto o motor não afirma: ele deixa a pergunta em pé.
  c_limite constant numeric := 0.75;
  v_atual  text;
  v_ok     boolean;
begin
  -- A opção tem que ser deste salão E da dimensão declarada. Sem isto, um
  -- uuid alucinado pelo modelo entraria como classificação válida.
  select true into v_ok
    from app.knowledge_options o
    join app.knowledge_dimensions d
      on d.id = o.dimension_id and d.tenant_id = o.tenant_id
   where o.id = p_option_id
     and o.dimension_id = p_dimension_id
     and o.tenant_id = p_tenant_id
     and o.status = 'ACTIVE'
     and d.status = 'ACTIVE';
  if not coalesce(v_ok, false) then
    return 'OPCAO_INVALIDA';
  end if;

  if p_source <> 'PESSOA' and coalesce(p_confidence, 0) < c_limite then
    return 'ABAIXO_DO_LIMITE';
  end if;

  select source into v_atual
    from app.client_classifications
   where profile_id = p_profile_id and dimension_id = p_dimension_id;

  if v_atual = 'PESSOA' and p_source <> 'PESSOA' then
    return 'PESSOA_JA_RESPONDEU';
  end if;

  insert into app.client_classifications (
    tenant_id, profile_id, dimension_id, option_id, confidence, source,
    decided_at, evidence_message_id
  ) values (
    p_tenant_id, p_profile_id, p_dimension_id, p_option_id,
    case when p_source = 'PESSOA' then null else p_confidence end,
    p_source, statement_timestamp(), p_message_id
  )
  on conflict (profile_id, dimension_id) do update
    set option_id           = excluded.option_id,
        confidence          = excluded.confidence,
        source              = excluded.source,
        decided_at          = excluded.decided_at,
        evidence_message_id = excluded.evidence_message_id,
        updated_at          = statement_timestamp();

  -- Espelho nas colunas antigas, enquanto elas existirem. O nome da dimensão é
  -- usado SÓ aqui, e só para o espelho: o caminho geral não depende de nome
  -- nenhum, senão um salão que chamasse a dimensão de "Tamanho" quebraria.
  update app.client_profiles p
     set length_option_id = case
           when lower(d.name) like 'compriment%' then p_option_id else p.length_option_id end,
         thickness_option_id = case
           when lower(d.name) like 'espessur%' then p_option_id else p.thickness_option_id end,
         updated_at = statement_timestamp()
    from app.knowledge_dimensions d
   where d.id = p_dimension_id
     and p.id = p_profile_id
     and p.tenant_id = p_tenant_id;

  return 'GRAVADO';
end;
$function$;

revoke all on function app.set_client_classification(uuid, uuid, uuid, uuid, text, numeric, uuid)
  from public, anon, authenticated;
grant execute on function app.set_client_classification(uuid, uuid, uuid, uuid, text, numeric, uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- A lista de pendências passa a sair da régua, não de uma lista fixa.
--
-- Antes: a linha 8 era "COMPRIMENTO -- seu cabelo é curto, médio ou comprido?",
-- escrita à mão, para uma dimensão específica. Um salão que criasse "Volume"
-- nunca teria essa pergunta feita.
--
-- Agora: cada dimensão ATIVA sem resposta vira uma pendência, com a pergunta
-- montada a partir do nome que o próprio salão deu e das opções que ele
-- cadastrou. Salão sem régua cadastrada não recebe pendência nenhuma -- cobrar
-- classificação de quem não cadastrou a régua é cobrar o impossível.
-- ---------------------------------------------------------------------------
create or replace function app.client_profile_missing(
  p_tenant_id  uuid,
  p_profile_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with p as (
    select * from app.client_profiles
     where tenant_id = p_tenant_id and id = p_profile_id
  ),
  tem_foto as (
    select exists (
             select 1 from app.client_photos f
              where f.tenant_id = p_tenant_id and f.profile_id = p_profile_id
                and f.kind = 'CABELO_ATUAL'
           )
           or coalesce((select hair_photo_seen_at > (statement_timestamp() - interval '120 days')
                          from p), false)
           as sim
  ),
  fixas as (
    select * from (values
      (1, 'FOTO_ATUAL',       'Manda uma foto do seu cabelo hoje, como ele está?',
          (select not coalesce(sim, false) from tem_foto)),
      (2, 'TEM_QUIMICA',      'Você já fez alguma química no cabelo?',
          coalesce((select has_chemistry is null from p), true)),
      (3, 'QUANDO_A_QUIMICA', 'Faz quanto tempo que você fez a última química?',
          coalesce((select coalesce(has_chemistry, false) and chemistry_last_at is null from p), false)),
      (4, 'QUIMICA_COM_FORMOL','Você sabe se essa química tinha formol?',
          coalesce((select coalesce(has_chemistry, false) and chemistry_formol is null from p), false)),
      (5, 'TEM_COLORACAO',    'Seu cabelo é colorido ou tem tintura?',
          coalesce((select has_color is null from p), true)),
      (6, 'QUANDO_COLORIU',   'Faz quanto tempo que você coloriu?',
          coalesce((select coalesce(has_color, false) and color_last_at is null from p), false)),
      (7, 'TOM_QUE_QUER',     'Me manda uma foto do tom que você quer alcançar?',
          coalesce((select tone_wanted is null from p), true))
    ) as v(ordem, campo, pergunta, falta)
     where falta
  ),
  da_regua as (
    select 10 + d.position as ordem,
           'CLASSIFICACAO:' || d.id::text as campo,
           -- A pergunta é montada com as palavras do próprio salão.
           'Seu cabelo é ' || (
             select string_agg(lower(o.label), ' ou ' order by o.position)
               from app.knowledge_options o
              where o.dimension_id = d.id and o.status = 'ACTIVE'
           ) || '?' as pergunta
      from app.knowledge_dimensions d
     where d.tenant_id = p_tenant_id
       and d.status = 'ACTIVE'
       and exists (select 1 from app.knowledge_options o
                    where o.dimension_id = d.id and o.status = 'ACTIVE')
       and not exists (select 1 from app.client_classifications c
                        where c.profile_id = p_profile_id and c.dimension_id = d.id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'campo', campo, 'perguntaSugerida', pergunta
         ) order by ordem), '[]'::jsonb)
    from (select ordem, campo, pergunta from fixas
          union all
          select ordem, campo, pergunta from da_regua) tudo;
$function$;

revoke all on function app.client_profile_missing(uuid, uuid) from public, anon, authenticated;
grant execute on function app.client_profile_missing(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- "Falta classificar" deixa de olhar duas colunas e passa a olhar a régua.
-- ---------------------------------------------------------------------------
create or replace function app.client_profile_pendencias(p_profile app.client_profiles)
returns text[]
language sql
stable
security definer
set search_path to ''
as $function$
  select array_remove(array[
    case when coalesce(trim(p_profile.preferred_name), '') = '' then 'NOME' end,
    case when p_profile.has_chemistry is null then 'QUIMICA' end,
    case when p_profile.photo_consent_granted_at is null then 'CONSENTIMENTO' end,
    case when exists (select 1 from app.knowledge_dimensions d
                       where d.tenant_id = p_profile.tenant_id and d.status = 'ACTIVE')
              and exists (select 1 from app.knowledge_dimensions d
                           where d.tenant_id = p_profile.tenant_id and d.status = 'ACTIVE'
                             and not exists (select 1 from app.client_classifications c
                                              where c.profile_id = p_profile.id
                                                and c.dimension_id = d.id))
         then 'CLASSIFICACAO' end,
    case when not exists (select 1 from app.client_procedures c where c.profile_id = p_profile.id)
         then 'PROCEDIMENTOS' end
  ], null);
$function$;

revoke all on function app.client_profile_pendencias(app.client_profiles) from public, anon, authenticated;
grant execute on function app.client_profile_pendencias(app.client_profiles) to service_role;
