-- A PAUSA E O QUE FAZ CABER MAIS GENTE NO DIA.
--
-- 23/09/2026, conversa real. A dona passou 45 minutos tentando dizer ao Eddy
-- que o botox tem 30 minutos de pausa, a progressiva sem formol tem uma hora,
-- o selante sem formol tem 40 minutos. Ao fim, `service_steps` com
-- `kind = 'PASSIVE'` no salao dela: ZERO.
--
-- O Eddy perguntou tres vezes a mesma coisa, contou para ela quatro vezes que
-- o sistema tinha recusado, e terminou em HANDOFF. Ele nao estava confuso: ele
-- estava tentando gravar uma informacao que nao tem onde cair.
--
-- `onboarding_criar_servico` aceita UM numero de minutos e cria UMA etapa
-- chamada "Execucao". Nao ha como dizer "dessas 2h30, 30 minutos a
-- profissional esta livre".
--
-- POR QUE ISSO NAO E DETALHE. Durante a pausa a CLIENTE esta ocupada e a
-- PROFISSIONAL nao. E isso, e so isso, que permite encaixar outra cliente no
-- meio -- e portanto e isso que decide quantas pessoas cabem no dia. Um salao
-- que registra progressiva como 3h30 de ocupacao continua perde as 60 minutos
-- em que daria para atender mais alguem. Nao e precisao de cadastro, e
-- faturamento.
--
-- O modelo ja sabia disso desde agosto: `app.service_steps` tem `kind`
-- PASSIVE, `releases_member` e `customer_presence_required`. O catalogo do
-- piloto, escrito a mao em 21/08, usa os tres. O que faltou foi a mao do Eddy.
--
-- "CONTA DENTRO OU SOMA A MAIS" E A PERGUNTA CERTA, E ELA E DA DONA.
-- Ela mesma fez essa distincao na conversa ("nesse caso esta dentro do
-- total"). Entao o parametro existe com esse nome e nao com outro: quem usa a
-- ferramenta pensa em total de atendimento, nao em soma de etapas.

create or replace function app.onboarding_definir_pausa(
  p_tenant_id      uuid,
  p_servico        text,
  p_minutos        integer,
  p_dentro_do_total boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome      text := nullif(trim(coalesce(p_servico, '')), '');
  v_rascunho  uuid;
  v_servico   uuid;
  v_ativa     record;
  v_quantas   integer;
  v_nova_ativa integer;
  v_total_antes integer;
begin
  if v_nome is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_INFORMADO');
  end if;
  if p_minutos is null or p_minutos < 5 or p_minutos > 480 then
    return jsonb_build_object('ok', false, 'reason', 'PAUSA_FORA_DE_FAIXA');
  end if;

  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  select s.id into v_servico
    from app.services s
   where s.tenant_id = p_tenant_id
     and s.configuration_draft_id = v_rascunho
     and s.status = 'ACTIVE'
     and lower(s.name) = lower(v_nome)
   limit 1;

  if v_servico is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_EXISTE', 'servico', v_nome);
  end if;

  -- Uma pausa so por servico, por enquanto. Procedimento com duas pausas
  -- existe (a hidratacao Joico do piloto tem tres), mas isso e conversa de
  -- etapas, nao de pausa -- e prometer que cabe aqui seria gravar errado.
  if exists (
    select 1 from app.service_steps t
     where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho
       and t.service_id = v_servico and t.kind = 'PASSIVE'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_JA_TEM_PAUSA', 'servico', v_nome);
  end if;

  select count(*) into v_quantas
    from app.service_steps t
   where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho
     and t.service_id = v_servico and t.kind = 'ACTIVE';

  if v_quantas <> 1 then
    -- Servico com varias etapas ativas veio do configurador ou do catalogo, e
    -- dividir "a" etapa deixa de fazer sentido. Recusar e melhor que escolher
    -- uma etapa por conta propria.
    return jsonb_build_object(
      'ok', false, 'reason', 'SERVICO_TEM_ETAPAS_DEMAIS',
      'etapasAtivas', v_quantas,
      'comoResolver', 'Este servico tem mais de uma etapa. A pausa dele precisa ser ajustada na tela do configurador.');
  end if;

  select t.id, t.duration_minutes, t.position into v_ativa
    from app.service_steps t
   where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho
     and t.service_id = v_servico and t.kind = 'ACTIVE'
   limit 1;

  v_total_antes := v_ativa.duration_minutes;

  if p_dentro_do_total then
    v_nova_ativa := v_total_antes - p_minutos;
    -- "A pausa cabe dentro das 2h30" so e verdade se sobrar atendimento.
    -- Sem esta trava, dizer "pausa de 2h30 dentro de 2h30" gravaria um
    -- servico de duracao zero que a agenda ofereceria como instantaneo.
    if v_nova_ativa < 5 then
      return jsonb_build_object(
        'ok', false, 'reason', 'PAUSA_MAIOR_QUE_O_SERVICO',
        'totalAtual', v_total_antes, 'pausaPedida', p_minutos,
        'comoResolver', 'A pausa nao cabe dentro do total. Confirme com ele se ela soma a mais.');
    end if;
    update app.service_steps
       set duration_minutes = v_nova_ativa,
           minimum_duration_minutes = v_nova_ativa,
           maximum_duration_minutes = v_nova_ativa,
           updated_at = statement_timestamp()
     where id = v_ativa.id;
  else
    v_nova_ativa := v_total_antes;
  end if;

  insert into app.service_steps (
    tenant_id, configuration_draft_id, service_id, name, position,
    duration_minutes, minimum_duration_minutes, maximum_duration_minutes,
    kind, technical_category, customer_presence_required, releases_member
  ) values (
    p_tenant_id, v_rascunho, v_servico, 'Pausa', v_ativa.position + 1,
    p_minutos, p_minutos, p_minutos,
    'PASSIVE'::app.step_kind, 'PROCESS'::app.technical_step_category,
    -- A cliente fica; a profissional sai. E esta segunda linha que libera a
    -- agenda para outra pessoa no mesmo horario.
    true, true
  );

  return jsonb_build_object(
    'ok', true, 'servico', v_nome, 'pausaMinutos', p_minutos,
    'dentroDoTotal', p_dentro_do_total,
    'atendimentoMinutos', v_nova_ativa,
    'totalMinutos', v_nova_ativa + p_minutos,
    'liberaProfissional', true
  );
end;
$fn$;

comment on function app.onboarding_definir_pausa(uuid, text, integer, boolean) is
  'Divide o servico em atendimento + pausa. Durante a pausa a cliente fica e a profissional sai, que e o que permite encaixar outra cliente no mesmo horario.';
revoke all on function app.onboarding_definir_pausa(uuid, text, integer, boolean) from public, anon, authenticated;
grant execute on function app.onboarding_definir_pausa(uuid, text, integer, boolean) to service_role;

-- A porta publica. Nove ferramentas viveram dois dias sem esta linha em
-- 21 e 23/09; nao vai acontecer uma terceira vez.
create or replace function public.onboarding_definir_pausa(
  p_tenant_id uuid, p_servico text, p_minutos integer, p_dentro_do_total boolean default true
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_definir_pausa(p_tenant_id, p_servico, p_minutos, p_dentro_do_total); $$;
revoke all on function public.onboarding_definir_pausa(uuid, text, integer, boolean) from public, anon, authenticated;
grant execute on function public.onboarding_definir_pausa(uuid, text, integer, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- O MANUAL PRECISA CITAR A FERRAMENTA, SENAO ELA NAO EXISTE PARA ELE.
-- ---------------------------------------------------------------------------

update app.agent_prompt_blocks
   set body = replace(
         body,
         '`definir_preco` — é por aqui que preço se grava. Sempre.',
         '`definir_pausa` — quando um procedimento tem tempo de espera do produto. Pergunte sempre se a pausa está dentro do tempo total ou soma a mais, e se nesse tempo dá para atender outra cliente.

`definir_preco` — é por aqui que preço se grava. Sempre.'),
       updated_at = statement_timestamp()
 where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER'
   and body not like '%definir_pausa%';

insert into app.agent_prompt_blocks (agent, code, title, body, position, status)
values ('DONO', 'EDDY_A_PAUSA_VALE_DINHEIRO', 'A pausa é o que faz caber mais gente no dia',
$txt$A PAUSA NÃO É DETALHE DE CADASTRO
Quando ele descrever um procedimento, pergunte se tem tempo de espera do produto — e quanto. Quase todo alisamento, coloração e tratamento tem.

Durante a pausa a cliente fica no salão, mas a profissional está livre. É isso, e só isso, que permite encaixar outra cliente no meio. Um salão que cadastra progressiva como três horas e meia de ocupação contínua perde a hora em que daria para atender mais alguém — e o dono não vai entender por que a agenda dele vive cheia e faturando pouco.

Duas perguntas, sempre as duas:
- quantos minutos de pausa?
- essa pausa está dentro do tempo total que você me falou, ou soma a mais?

A segunda importa porque "duas horas e meia com meia hora de pausa" pode querer dizer duas coisas diferentes, e cadastrar a errada tira meia hora do dia dele ou promete meia hora que não existe.

Se ele disser que durante a pausa a profissional continua ocupada com a mesma cliente, então não é pausa: é atendimento, e entra no tempo normal.$txt$, 56, 'ACTIVE')
on conflict (code) do update
   set agent = excluded.agent, title = excluded.title, body = excluded.body,
       position = excluded.position, status = 'ACTIVE', updated_at = statement_timestamp();
