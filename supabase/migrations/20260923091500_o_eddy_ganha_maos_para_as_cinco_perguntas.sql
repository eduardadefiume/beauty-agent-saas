-- O EDDY GANHA MAOS PARA AS CINCO PERGUNTAS QUE ELE JA FAZIA.
--
-- 23/09/2026. Num salao vazio, `app.owner_setup_state` devolve cinco pendencias,
-- na ordem certa, com a pergunta pronta:
--
--   UNIDADE       "Como se chama o seu salao, e onde ele fica?"
--   HORARIOS      "Que dias e horarios o salao atende?"
--   PROFISSIONAIS "Quem atende no salao? Me fala os nomes."
--   SERVICOS      "Quais servicos voce faz?"
--   REGRAS        "Tem alguma regra sua que a atendente precisa saber?"
--
-- O catalogo sempre esteve certo. O que faltava eram as MAOS: das cinco, o Eddy
-- so conseguia gravar a ultima (`anotar`). Ele perguntaria o nome do salao, a
-- dona responderia, e a resposta nao teria onde cair -- ele diria "anotei"
-- mentindo, e a pergunta voltaria na mensagem seguinte, em loop.
--
-- A CORRENTE QUE MANDA NA ORDEM. `onboarding_criar_servico` exige habilidade
-- que tenha um PROFISSIONAL ATIVO que a faca. Entao a ordem nao e escolha de
-- prompt, e do modelo de dados:
--
--        equipe  ->  habilidade  ->  servico
--
-- Por isso `criar_habilidade` recusa quando o salao nao tem ninguem, e devolve
-- a pergunta que destrava. O Eddy nao precisa saber a ordem: o banco ensina.
--
-- DIA DA SEMANA: 0 e domingo, 6 e sabado. Nao ha check constraint nem comentario
-- no banco dizendo isso -- a convencao mora em scheduling-engine.ts
-- ("weekday: number; // 0 (domingo) .. 6 (sabado)"). Fica escrito aqui tambem,
-- porque errar isso desloca o salao um dia inteiro e ninguem percebe.

-- ---------------------------------------------------------------------------
-- 1. IDENTIDADE: o nome do salao e onde ele fica.
--
-- `units` e do TENANT, nao do rascunho -- por isso aqui nao ha clone. O nome do
-- salao nao e versionado como preco e servico sao: ele so e.
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_registrar_identidade(
  p_tenant_id uuid,
  p_nome      text,
  p_endereco  text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome     text := nullif(trim(coalesce(p_nome, '')), '');
  v_endereco text := nullif(trim(coalesce(p_endereco, '')), '');
  v_unidade  uuid;
  v_antes    text;
begin
  if v_nome is null or length(v_nome) < 2 or length(v_nome) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_FORA_DE_FAIXA');
  end if;

  -- Endereco pela metade e pior que endereco nenhum: a cliente sai para a rua
  -- com ele. Ou vem inteiro, ou nao vem.
  if v_endereco is not null and length(v_endereco) < 10 then
    return jsonb_build_object('ok', false, 'reason', 'ENDERECO_CURTO_DEMAIS');
  end if;

  select u.id, u.name into v_unidade, v_antes
    from app.units u
   where u.tenant_id = p_tenant_id
   order by u.created_at
   limit 1;

  if v_unidade is null then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_SEM_UNIDADE');
  end if;

  update app.units
     set name         = v_nome,
         address_json = case
                          when v_endereco is null then address_json
                          else jsonb_build_object('texto', v_endereco)
                        end,
         updated_at   = statement_timestamp()
   where id = v_unidade;

  return jsonb_build_object(
    'ok', true,
    'salao', v_nome,
    'endereco', v_endereco,
    'antes', jsonb_build_object('nome', v_antes)
  );
end;
$fn$;

comment on function app.onboarding_registrar_identidade(uuid, text, text) is
  'Grava o nome do salao e o endereco na unidade. Responde a pendencia UNIDADE.';
revoke all on function app.onboarding_registrar_identidade(uuid, text, text) from public, anon, authenticated;
grant execute on function app.onboarding_registrar_identidade(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. QUEM ATENDE NO SALAO.
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_criar_membro_equipe(
  p_tenant_id uuid,
  p_nome      text,
  p_tipo      text default 'PROFESSIONAL'
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome     text := nullif(trim(coalesce(p_nome, '')), '');
  v_tipo     text := upper(nullif(trim(coalesce(p_tipo, '')), ''));
  v_rascunho uuid;
  v_id       uuid;
begin
  if v_nome is null or length(v_nome) < 2 or length(v_nome) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_FORA_DE_FAIXA');
  end if;

  v_tipo := coalesce(v_tipo, 'PROFESSIONAL');
  if v_tipo not in ('PROFESSIONAL', 'ASSISTANT') then
    return jsonb_build_object('ok', false, 'reason', 'TIPO_INVALIDO');
  end if;

  -- Devolve o rascunho aberto quando ja existe um; so clona do publicado
  -- quando nao ha. Salao recem-nascido cai no primeiro caso.
  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  if exists (
    select 1 from app.team_members m
     where m.tenant_id = p_tenant_id
       and m.configuration_draft_id = v_rascunho
       and m.status = 'ACTIVE'
       and lower(m.name) = lower(v_nome)
  ) then
    return jsonb_build_object('ok', false, 'reason', 'PESSOA_JA_EXISTE', 'pessoa', v_nome);
  end if;

  insert into app.team_members (tenant_id, configuration_draft_id, name, member_type)
  values (p_tenant_id, v_rascunho, v_nome, v_tipo)
  returning id into v_id;

  return jsonb_build_object(
    'ok', true, 'pessoaId', v_id, 'pessoa', v_nome,
    'tipo', v_tipo, 'rascunho', v_rascunho
  );
end;
$fn$;

comment on function app.onboarding_criar_membro_equipe(uuid, text, text) is
  'Cadastra quem atende no salao. Responde a pendencia PROFISSIONAIS e e o primeiro elo de equipe -> habilidade -> servico.';
revoke all on function app.onboarding_criar_membro_equipe(uuid, text, text) from public, anon, authenticated;
grant execute on function app.onboarding_criar_membro_equipe(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. HABILIDADE, SEMPRE COM QUEM A FAZ.
--
-- Habilidade sem ninguem que a execute e invisivel para o `criar_servico` --
-- ele exige o vinculo. Entao criar habilidade solta produziria uma habilidade
-- que existe e nao serve para nada. Aqui as duas coisas nascem juntas.
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_criar_habilidade(
  p_tenant_id uuid,
  p_nome      text,
  p_quem_faz  text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome      text := nullif(trim(coalesce(p_nome, '')), '');
  v_rascunho  uuid;
  v_skill     uuid;
  v_nova      boolean := false;
  v_pessoa    text;
  v_pessoa_id uuid;
  v_ligadas   text[] := array[]::text[];
  v_sem_achar text[] := array[]::text[];
  v_equipe    integer;
begin
  if v_nome is null or length(v_nome) < 2 or length(v_nome) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_FORA_DE_FAIXA');
  end if;

  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  select count(*) into v_equipe
    from app.team_members m
   where m.tenant_id = p_tenant_id
     and m.configuration_draft_id = v_rascunho
     and m.status = 'ACTIVE';

  -- A recusa que ensina a ordem, em vez de so dizer nao.
  if v_equipe = 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'SALAO_SEM_EQUIPE',
      'pergunteAntes', 'Quem atende no salao? Me fala os nomes.');
  end if;

  select k.id into v_skill
    from app.skills k
   where k.tenant_id = p_tenant_id
     and k.configuration_draft_id = v_rascunho
     and k.status = 'ACTIVE'
     and lower(k.name) = lower(v_nome)
   limit 1;

  if v_skill is null then
    insert into app.skills (tenant_id, configuration_draft_id, name)
    values (p_tenant_id, v_rascunho, v_nome)
    returning id into v_skill;
    v_nova := true;
  end if;

  -- Sem nomes, a habilidade vale para o salao inteiro: e o caso do salao de uma
  -- pessoa so, que e a maioria de quem vai comprar isso.
  if p_quem_faz is null or cardinality(p_quem_faz) = 0 then
    for v_pessoa_id, v_pessoa in
      select m.id, m.name from app.team_members m
       where m.tenant_id = p_tenant_id
         and m.configuration_draft_id = v_rascunho
         and m.status = 'ACTIVE'
    loop
      if not exists (
        select 1 from app.member_skills ms
         where ms.tenant_id = p_tenant_id
           and ms.configuration_draft_id = v_rascunho
           and ms.member_id = v_pessoa_id and ms.skill_id = v_skill
      ) then
        insert into app.member_skills (tenant_id, configuration_draft_id, member_id, skill_id)
        values (p_tenant_id, v_rascunho, v_pessoa_id, v_skill);
      end if;
      v_ligadas := v_ligadas || v_pessoa;
    end loop;
  else
    foreach v_pessoa in array p_quem_faz loop
      v_pessoa := trim(coalesce(v_pessoa, ''));
      continue when v_pessoa = '';

      select m.id into v_pessoa_id
        from app.team_members m
       where m.tenant_id = p_tenant_id
         and m.configuration_draft_id = v_rascunho
         and m.status = 'ACTIVE'
         and lower(m.name) = lower(v_pessoa)
       limit 1;

      if v_pessoa_id is null then
        v_sem_achar := v_sem_achar || v_pessoa;
        continue;
      end if;

      if not exists (
        select 1 from app.member_skills ms
         where ms.tenant_id = p_tenant_id
           and ms.configuration_draft_id = v_rascunho
           and ms.member_id = v_pessoa_id and ms.skill_id = v_skill
      ) then
        insert into app.member_skills (tenant_id, configuration_draft_id, member_id, skill_id)
        values (p_tenant_id, v_rascunho, v_pessoa_id, v_skill);
      end if;
      v_ligadas := v_ligadas || v_pessoa;
    end loop;
  end if;

  -- Habilidade criada e ligada a ninguem continua invisivel para o servico.
  -- Dizer "ok" aqui seria a mesma mentira do "anotei" que este trabalho veio
  -- consertar.
  if cardinality(v_ligadas) = 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'NINGUEM_RECONHECIDO',
      'naoEncontrados', to_jsonb(v_sem_achar));
  end if;

  return jsonb_build_object(
    'ok', true, 'habilidade', v_nome, 'habilidadeNova', v_nova,
    'quemFaz', to_jsonb(v_ligadas),
    'naoEncontrados', to_jsonb(v_sem_achar),
    'rascunho', v_rascunho
  );
end;
$fn$;

comment on function app.onboarding_criar_habilidade(uuid, text, text[]) is
  'Cria a habilidade E liga a quem a faz. Sem o vinculo ela fica invisivel para onboarding_criar_servico. Sem nomes, vale para a equipe inteira.';
revoke all on function app.onboarding_criar_habilidade(uuid, text, text[]) from public, anon, authenticated;
grant execute on function app.onboarding_criar_habilidade(uuid, text, text[]) to service_role;

-- ---------------------------------------------------------------------------
-- 4. OS DIAS E HORARIOS.
--
-- Substitui o horario inteiro, nao acrescenta: "o salao abre de terca a sabado"
-- e uma frase sobre a semana toda. Acrescentar deixaria resto de uma resposta
-- anterior e o salao atenderia em dia que a dona nunca disse.
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_definir_horario_funcionamento(
  p_tenant_id uuid,
  p_dias      jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
  v_item     jsonb;
  v_dia      integer;
  v_abre     time;
  v_fecha    time;
  v_gravados jsonb := '[]'::jsonb;
  v_nomes    text[] := array['domingo','segunda','terca','quarta','quinta','sexta','sabado'];
begin
  if p_dias is null or jsonb_typeof(p_dias) <> 'array' or jsonb_array_length(p_dias) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'DIAS_NAO_INFORMADOS');
  end if;

  if jsonb_array_length(p_dias) > 14 then
    return jsonb_build_object('ok', false, 'reason', 'DIAS_DEMAIS');
  end if;

  -- Valida TUDO antes de apagar qualquer coisa: uma faixa errada no meio nao
  -- pode deixar o salao sem horario nenhum.
  for v_item in select * from jsonb_array_elements(p_dias) loop
    begin
      v_dia   := (v_item->>'dia')::integer;
      v_abre  := (v_item->>'abre')::time;
      v_fecha := (v_item->>'fecha')::time;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'FORMATO_INVALIDO', 'item', v_item);
    end;

    if v_dia is null or v_dia < 0 or v_dia > 6 then
      return jsonb_build_object('ok', false, 'reason', 'DIA_FORA_DE_FAIXA', 'item', v_item);
    end if;
    if v_abre is null or v_fecha is null or v_abre >= v_fecha then
      return jsonb_build_object('ok', false, 'reason', 'HORARIO_INVERTIDO', 'item', v_item);
    end if;
  end loop;

  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  delete from app.operating_hours
   where tenant_id = p_tenant_id and configuration_draft_id = v_rascunho;

  for v_item in select * from jsonb_array_elements(p_dias) loop
    v_dia   := (v_item->>'dia')::integer;
    v_abre  := (v_item->>'abre')::time;
    v_fecha := (v_item->>'fecha')::time;

    insert into app.operating_hours (tenant_id, configuration_draft_id, weekday, starts_at, ends_at)
    values (p_tenant_id, v_rascunho, v_dia, v_abre, v_fecha)
    on conflict do nothing;

    v_gravados := v_gravados || jsonb_build_object(
      'dia', v_nomes[v_dia + 1], 'abre', v_abre::text, 'fecha', v_fecha::text);
  end loop;

  return jsonb_build_object('ok', true, 'horarios', v_gravados, 'rascunho', v_rascunho);
end;
$fn$;

comment on function app.onboarding_definir_horario_funcionamento(uuid, jsonb) is
  'Define a semana inteira de uma vez. dia: 0=domingo .. 6=sabado (convencao do scheduling-engine). Substitui, nao acrescenta.';
revoke all on function app.onboarding_definir_horario_funcionamento(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.onboarding_definir_horario_funcionamento(uuid, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 5. O MANUAL DELE PRECISA CITAR AS MAOS NOVAS.
--
-- A licao de 18/09, que custou uma tarde: ferramenta na mao e bloco de prompt
-- que nao a cita e o mesmo que nao ter a ferramenta. O Eddy le
-- "ONDE VOCE PODE ESCREVER" como lista FECHADA -- e com razao, porque e assim
-- que ela esta escrita. Acrescentar funcao sem acrescentar linha aqui seria
-- repetir o erro de proposito.
-- ---------------------------------------------------------------------------

update app.agent_prompt_blocks
   set body = $txt$ONDE VOCÊ PODE ESCREVER
Você escreve nos lugares que as suas ferramentas alcançam, e nada do que você escreve vale para cliente nenhuma enquanto ele não publicar.

`registrar_identidade` — o nome do salão e o endereço. Endereço pela metade não serve: a cliente sai para a rua com ele.

`criar_membro_equipe` — quem atende no salão, um por chamada. Num salão de uma pessoa só, o dono também entra aqui: ele atende.

`criar_habilidade` — o que a equipe sabe fazer (corte, coloração, mechas). Ela nasce ligada a quem faz, senão não serve para nada.

`definir_horario_funcionamento` — os dias e horários, a semana inteira de uma vez. Ela substitui o que havia, não acrescenta.

`criar_servico` — cria serviço que ainda não existe no catálogo dele.

`definir_preco` — é por aqui que preço se grava. Sempre.

`criar_variacao` — quando o mesmo serviço tem mais de um preço, cada preço é uma chamada.

`desativar_servico` — tira do catálogo o que ele não faz. Só depois de ele confirmar.

`anotar` — responde pendência de regra. Cada uma tem uma chave que vem na lista. Você NUNCA inventa uma chave: usa as que recebeu. Preço NÃO passa por aqui, e nome, endereço, equipe e horário também não: cada um tem a ferramenta dele acima.

`resumo` — o que mudou no rascunho e o que falta para publicar.

`publicar` — põe no ar o que ele já conferiu, no comando dele. Leia o bloco sobre publicar antes de usar.

O que continua NÃO sendo seu: ligar o agente para as clientes e conectar o WhatsApp. Essas duas são decisão dele, na tela. Você avisa quando estiver na hora e explica o que acontece, mas não faz por ele.

E quando ele pedir alguma coisa que nenhuma dessas ferramentas alcança: diga a ele que você não consegue fazer aquilo por ali, sem explicar o sistema por dentro, e encerre com HANDOFF. Nunca prometa "vou tentar de novo" nem "vou insistir". O pedido dele fica registrado e a Eduarda vê.$txt$,
       updated_at = statement_timestamp()
 where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER';

-- ---------------------------------------------------------------------------
-- 6. O SALAO QUE NASCE VAZIO TEM UMA ORDEM, E ELA NAO E OPINIAO.
-- ---------------------------------------------------------------------------

-- `title` e NOT NULL e nao tem default: faltou na primeira versao deste
-- arquivo e so apareceu porque eu fui conferir coluna a coluna em vez de
-- esperar o proximo push falhar.
insert into app.agent_prompt_blocks (agent, code, title, body, position, status)
values ('DONO', 'EDDY_O_SALAO_QUE_NASCE_VAZIO',
        'A ordem das cinco perguntas num salão recém-nascido',
        $txt$O SALÃO QUE COMEÇA DO ZERO
Quando ele chega sem nada cadastrado, a lista de pendências vem com cinco coisas e a ordem delas importa, porque uma destrava a outra:

1. O nome do salão e onde ele fica.
2. Quem atende no salão.
3. O que essas pessoas sabem fazer.
4. Os serviços, com preço.
5. As regras dele.

Serviço exige habilidade, e habilidade exige alguém que a faça. Então você não consegue cadastrar "Progressiva" antes de saber quem trabalha ali — e isso não é implicância do sistema, é que serviço sem ninguém para executar não pode ser agendado.

Se você tentar fora de ordem, a ferramenta te diz o que perguntar antes. Não insista, não invente um nome de profissional, e não peça as cinco coisas de uma vez: uma pergunta por mensagem, como sempre.

E os horários você pode pedir a qualquer momento, não dependem de nada.$txt$, 61, 'ACTIVE')
-- A chave unica desta tabela e `code` SOZINHO, nao (agent, code). Eu supus o
-- par e o push falhou inteiro -- conferido depois em pg_constraint:
-- "UNIQUE (code) | PRIMARY KEY (id)". Fica anotado porque o nome da tabela
-- sugere que o mesmo code possa existir para agentes diferentes, e nao pode.
on conflict (code) do update
   set agent = excluded.agent, body = excluded.body, position = excluded.position,
       status = 'ACTIVE', updated_at = statement_timestamp();
