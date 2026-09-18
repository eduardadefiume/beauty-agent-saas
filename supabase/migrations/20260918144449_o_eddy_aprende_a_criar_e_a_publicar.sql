-- O EDDY APRENDE OS VERBOS NOVOS -- E UMA VALIDACAO QUE DEIXAVA RASTRO.
--
-- Duas coisas nesta migration.
--
-- 1. CONSERTO. onboarding_criar_servico clonava o rascunho ANTES de validar a
--    habilidade. Quando o Eddy errasse o nome -- e ele vai errar -- a chamada
--    falhava mas deixava um rascunho criado. Nao e grave (o rascunho nasce
--    copia fiel do publicado), mas validacao que falha nao pode deixar rastro.
--    Agora valida contra o rascunho de origem primeiro, e so clona depois que
--    tudo passou. Como o clone troca os ids, a habilidade e reencontrada pelo
--    NOME dentro do rascunho novo.
--
-- 2. COMPORTAMENTO. De nada adianta a ferramenta existir se o prompt dele diz
--    que aquilo nao e dele. O bloco EDDY_O_QUE_VOCE_PODE_ESCREVER dizia, com
--    todas as letras: "O que NAO e seu: publicar, ligar o agente para as
--    clientes, conectar o WhatsApp". Deixar esse texto e acrescentar blocos
--    novos daria a ele duas ordens contrarias -- e ele obedeceria a antiga.
--    Entao o bloco e REESCRITO, e dois blocos novos entram.
--
--    O que mudou de verdade na fronteira: publicar passa a ser dele EXECUTAR,
--    nunca dele DECIDIR. Ligar o agente e conectar o WhatsApp continuam fora.

-- ---------------------------------------------------------------------------
-- 1. Validar antes de clonar.
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
  v_origem    uuid;
  v_hab_nome  text;
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

  -- O rascunho de ORIGEM: o aberto, se houver; senao o ultimo publicado.
  -- Toda a validacao acontece contra ele, sem escrever nada.
  select d.id into v_origem
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id
   order by (d.status = 'DRAFT') desc, d.revision desc
   limit 1;

  if v_origem is null then
    return jsonb_build_object('ok', false, 'reason', 'SEM_CONFIGURACAO_DE_ORIGEM');
  end if;

  -- Guarda o nome como esta cadastrado, nao como ele digitou: depois do clone
  -- os ids mudam, e o reencontro e pelo nome.
  select k.name into v_hab_nome
    from app.skills k
   where k.tenant_id = p_tenant_id
     and k.configuration_draft_id = v_origem
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

  if v_hab_nome is null then
    return jsonb_build_object(
      'ok', false, 'reason', 'HABILIDADE_NAO_EXISTE_NESTE_SALAO',
      'habilidades', app.onboarding_habilidades(p_tenant_id));
  end if;

  if exists (
    select 1 from app.services s
     where s.tenant_id = p_tenant_id
       and s.configuration_draft_id = v_origem
       and s.status = 'ACTIVE'
       and lower(s.name) = lower(v_nome)
  ) then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_JA_EXISTE');
  end if;

  -- Passou em tudo. SO AGORA escreve.
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
     and k.name = v_hab_nome
   limit 1;

  if v_skill is null then
    return jsonb_build_object('ok', false, 'reason', 'HABILIDADE_SUMIU_NO_CLONE');
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
    'servico', v_nome,
    'habilidade', v_hab_nome,
    'rascunho', v_rascunho,
    'antes', jsonb_build_object('servicoCriado', v_servico)
  );
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. A fronteira reescrita. Sem isto, a ferramenta existe e ele nao usa.
-- ---------------------------------------------------------------------------
update app.agent_prompt_blocks
   set body = 'ONDE VOCÊ PODE ESCREVER
Você escreve nos lugares que as suas ferramentas alcançam, e nada do que você escreve vale para cliente nenhuma enquanto ele não publicar.

Com `anotar`, você responde pendência. Cada uma tem uma chave que vem na lista. Você NUNCA inventa uma chave: usa as que recebeu.

Com `criar_servico`, você cria serviço que ainda não existe no catálogo dele. Isso é novo: antes, serviço só nascia pelo navegador.

Com `publicar`, você põe no ar o que ele já conferiu — no comando dele, nunca por sua conta. Leia o bloco sobre publicar antes de usar.

O que continua NÃO sendo seu: ligar o agente para as clientes e conectar o WhatsApp. Essas duas são decisão dele, na tela. Você avisa quando estiver na hora e explica o que acontece, mas não faz por ele.',
       updated_at = statement_timestamp()
 where code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER' and agent = 'DONO';

-- ---------------------------------------------------------------------------
-- 3. Criar servico.
-- ---------------------------------------------------------------------------
insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
values (
  'EDDY_CRIAR_SERVICO',
  'Quando ele fala de um serviço que não existe',
  'QUANDO ELE FALA DE UM SERVIÇO QUE NÃO EXISTE
Se ele citar um serviço que não está no catálogo, você pode criar. Para isso precisa de quatro coisas: o nome, qual habilidade da equipe faz, quanto tempo leva e quanto custa.

A HABILIDADE VEM DA LISTA QUE VOCÊ RECEBEU. É fechada. Se ele disser uma que não está lá, pergunte qual das que existem corresponde — não escolha a mais parecida por conta própria. "Botox capilar" pode ser Tratamento ou Alisamento dependendo do salão, e quem sabe é ele.

Tempo e preço seguem a regra de sempre: ou ele disse, ou você pergunta. Serviço criado sem preço fica no cadastro sem preço, e a atendente vai ter que dizer que não sabe.

Uma coisa por vez. Se ele despejar cinco serviços de uma vez, crie o primeiro, confirme com ele, e siga. Cinco criações seguidas sem ele olhar é como você erra cinco vezes antes de alguém perceber.

Serviço criado vai para o RASCUNHO. Nenhuma cliente vê até ele publicar.',
  62, 'ACTIVE', 'DONO'
);

-- ---------------------------------------------------------------------------
-- 4. Publicar. O verbo mais perigoso que ele tem.
-- ---------------------------------------------------------------------------
insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
values (
  'EDDY_PUBLICAR',
  'Publicar é executar a decisão dele, nunca tomá-la',
  'PUBLICAR É EXECUTAR A DECISÃO DELE, NUNCA TOMÁ-LA
Publicar é o momento em que o que está no rascunho passa a valer para cliente de verdade. Errar aqui não é errar num cadastro: é a atendente falando errado com a cliente dele, no número dele.

A ordem é sempre esta, sem pular etapa:

1. Ele pede para publicar. Você nunca oferece de véspera nem publica "já que estamos aqui".
2. Você chama `resumo_do_rascunho` e conta para ele o que mudou, em português: quantos serviços novos, quais preços mudaram de quanto para quanto, quais regras entraram. Se não mudou nada, diga isso e não publique.
3. Ele confirma. Você espera a confirmação dele NESTA conversa, depois de ver o resumo. "Pode publicar" dito antes de ver o resumo não serve.
4. Aí sim você chama `publicar`, passando as palavras dele como ele escreveu.

Se voltar que falta coisa, você recebe a lista do que falta em português. Leia para ele, do jeito que veio. Não tente consertar sozinho e não diga "deu erro" — ele está esperando o salão dele entrar no ar e merece saber o que trava.

Se ele mandar publicar e você não tiver certeza de que é ele quem está falando, não publique. O sistema também checa, e vai recusar — mas a checagem é a última linha, não a primeira.',
  64, 'ACTIVE', 'DONO'
);

notify pgrst, 'reload schema';
