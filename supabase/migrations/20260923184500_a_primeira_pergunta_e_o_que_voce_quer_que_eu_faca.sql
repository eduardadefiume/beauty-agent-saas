-- A PRIMEIRA PERGUNTA E "O QUE VOCE QUER QUE EU FACA".
--
-- 23/09/2026, apontado pela dona do produto: o Eddy nunca perguntou ao dono
-- para que serve o agente. O onboarding presumia que ele faz tudo -- responde,
-- cota preco, marca horario -- e cobrava as mesmas nove coisas de todo salao.
--
-- ISSO NAO E UMA PERGUNTA FALTANDO, E UM CAMINHO FALTANDO. Um salao que so
-- quer "responde o horario e o preco, e me passa o resto" nao precisa de
-- disponibilidade por profissional nem de tempo de pausa do produto. Estava
-- preenchendo um motor de agenda que nunca ia usar.
--
-- Foi exatamente isso que cansou a dona hoje: 45 minutos falando de pausa de
-- produto, uma informacao que so existe porque o sistema presumiu que o agente
-- ia agendar.
--
-- E A ORDEM ESTAVA INVERTIDA. Esta pergunta nao e mais uma no fim da lista: e
-- a primeira, porque e ela que decide quais das outras existem.
--
-- TRES COISAS JA CONSTRUIDAS E NUNCA OFERECIDAS. `deposit_enabled` (o sinal,
-- funcionando desde agosto, com quatro registros no piloto) e
-- `cancellation_policy_enabled` existem em `configuration_drafts` e nenhum
-- dono jamais foi perguntado se quer usar. A escolha aqui LIGA esses
-- interruptores de verdade -- senao seria enquete, nao configuracao.

create table if not exists app.agent_scope (
  tenant_id                uuid primary key references app.tenants(id) on delete cascade,
  -- Responder e o piso: quem nao quer nem isso nao quer o produto.
  responde                 boolean not null default true,
  marca_horario            boolean not null default false,
  pede_sinal               boolean not null default false,
  politica_de_cancelamento boolean not null default false,
  -- Lembrete de vespera depende de modelo aprovado pela Meta, que depende do
  -- App Review. Fica na tabela para o dono poder pedir e a gente saber quantos
  -- pediram -- mas o Eddy diz a verdade: ainda nao da.
  lembra_da_vespera        boolean not null default false,
  respondido_em            timestamptz,
  respondido_por           text,
  created_at               timestamptz not null default statement_timestamp(),
  updated_at               timestamptz not null default statement_timestamp()
);

comment on table app.agent_scope is
  'O que o dono quer que o agente faca pelas clientes dele. respondido_em nulo quer dizer que ninguem perguntou ainda -- e enquanto for nulo, e a primeira pendencia.';

alter table app.agent_scope enable row level security;

-- ---------------------------------------------------------------------------
-- A ESCOLHA, E O QUE ELA LIGA DE VERDADE.
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_definir_o_que_o_agente_faz(
  p_tenant_id      uuid,
  p_marca_horario  boolean default false,
  p_pede_sinal     boolean default false,
  p_cancelamento   boolean default false,
  p_lembra_vespera boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
  v_marca    boolean := coalesce(p_marca_horario, false);
  v_sinal    boolean := coalesce(p_pede_sinal, false);
  v_cancel   boolean := coalesce(p_cancelamento, false);
  v_lembra   boolean := coalesce(p_lembra_vespera, false);
begin
  -- Sinal e politica de cancelamento so fazem sentido em cima de horario
  -- marcado. Aceitar "quero sinal mas nao quero agendar" gravaria uma
  -- configuracao que nao tem como funcionar.
  if (v_sinal or v_cancel) and not v_marca then
    return jsonb_build_object(
      'ok', false, 'reason', 'SINAL_E_CANCELAMENTO_PRECISAM_DE_AGENDA',
      'comoResolver', 'Pedir sinal e ter politica de cancelamento so valem se o agente marcar horario. Confirme com ele.');
  end if;

  insert into app.agent_scope as e (
    tenant_id, responde, marca_horario, pede_sinal,
    politica_de_cancelamento, lembra_da_vespera, respondido_em, respondido_por
  ) values (
    p_tenant_id, true, v_marca, v_sinal, v_cancel, v_lembra,
    statement_timestamp(), 'eddy@whatsapp'
  )
  on conflict (tenant_id) do update
    set responde                 = true,
        marca_horario            = excluded.marca_horario,
        pede_sinal               = excluded.pede_sinal,
        politica_de_cancelamento = excluded.politica_de_cancelamento,
        lembra_da_vespera        = excluded.lembra_da_vespera,
        respondido_em            = excluded.respondido_em,
        respondido_por           = excluded.respondido_por,
        updated_at               = statement_timestamp();

  -- A escolha LIGA os interruptores que ja existiam. Sem isto, seria enquete.
  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
    update app.configuration_drafts
       set deposit_enabled             = v_sinal,
           cancellation_policy_enabled = v_cancel,
           updated_at                  = statement_timestamp()
     where id = v_rascunho;
  exception when others then
    -- Sem rascunho aberto a escolha fica gravada mesmo assim: ela e do dono,
    -- nao da revisao. Os interruptores pegam na proxima vez.
    v_rascunho := null;
  end;

  return jsonb_build_object(
    'ok', true,
    'responde', true,
    'marcaHorario', v_marca,
    'pedeSinal', v_sinal,
    'politicaDeCancelamento', v_cancel,
    'lembraDaVespera', v_lembra,
    'lembreteAindaNaoDisponivel', v_lembra,
    'rascunho', v_rascunho
  );
end;
$fn$;

comment on function app.onboarding_definir_o_que_o_agente_faz(uuid, boolean, boolean, boolean, boolean) is
  'Grava o que o dono quer do agente e LIGA os interruptores correspondentes no rascunho. Responder e sempre verdadeiro: e o piso do produto.';
revoke all on function app.onboarding_definir_o_que_o_agente_faz(uuid, boolean, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function app.onboarding_definir_o_que_o_agente_faz(uuid, boolean, boolean, boolean, boolean) to service_role;

create or replace function public.onboarding_definir_o_que_o_agente_faz(
  p_tenant_id uuid, p_marca_horario boolean default false, p_pede_sinal boolean default false,
  p_cancelamento boolean default false, p_lembra_vespera boolean default false
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_definir_o_que_o_agente_faz(p_tenant_id, p_marca_horario, p_pede_sinal, p_cancelamento, p_lembra_vespera); $$;
revoke all on function public.onboarding_definir_o_que_o_agente_faz(uuid, boolean, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function public.onboarding_definir_o_que_o_agente_faz(uuid, boolean, boolean, boolean, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- O CATALOGO: a pergunta vem primeiro, e a resposta poda o resto.
-- ---------------------------------------------------------------------------

create or replace function app.owner_setup_state(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with unidade as (
    select u.* from app.units u
     where u.tenant_id = p_tenant_id
     order by u.created_at limit 1
  ),
  rascunho as (
    select d.* from app.configuration_drafts d
     where d.tenant_id = p_tenant_id
     order by d.revision desc limit 1
  ),
  escopo as (
    select e.* from app.agent_scope e where e.tenant_id = p_tenant_id
  ),
  n as (
    select
      (select name from unidade)                                              as unidade_nome,
      coalesce((select coalesce(address_json, '{}'::jsonb) <> '{}'::jsonb from unidade), false) as tem_endereco,
      coalesce((select active_configuration_version_id is not null from unidade), false)        as publicado,
      (select revision from rascunho)                                         as rascunho_rev,
      (select respondido_em is not null from escopo)                          as escopo_respondido,
      coalesce((select marca_horario from escopo), false)                     as marca_horario,
      (select count(*) from app.operating_hours h
        where h.tenant_id = p_tenant_id
          and h.configuration_draft_id = (select id from rascunho))            as horarios,
      (select count(*) from app.team_members m
        where m.tenant_id = p_tenant_id
          and m.configuration_draft_id = (select id from rascunho)
          and m.status = 'ACTIVE')                                             as profissionais,
      app.equipe_sem_disponibilidade(p_tenant_id)                              as sem_disponibilidade,
      (select count(*) from app.services s
        where s.tenant_id = p_tenant_id
          and s.configuration_draft_id = (select id from rascunho)
          and s.status = 'ACTIVE')                                             as servicos,
      (select count(*) from app.services s
        where s.tenant_id = p_tenant_id
          and s.configuration_draft_id = (select id from rascunho)
          and s.status = 'ACTIVE'
          and s.base_price_minor is null)                                      as servicos_sem_preco,
      (select count(*) from app.agent_policies p
        where p.tenant_id = p_tenant_id and p.status = 'ACTIVE')               as regras,
      (select count(*) from app.status_arts a
        where a.tenant_id = p_tenant_id and a.retired_at is null)              as artes,
      (select count(*) from app.channel_connections c
        where c.tenant_id = p_tenant_id and c.purpose = 'CLIENTE')             as canais
  ),
  falta as (
    select coalesce(jsonb_agg(item order by ordem), '[]'::jsonb) as lista from (
      -- ANTES DE TUDO. Enquanto nao houver resposta aqui, o resto nem aparece:
      -- perguntar servico e preco a quem ainda nao disse para que quer o
      -- agente e fazer o dono preencher formulario sem saber por que.
      select 5 as ordem, jsonb_build_object(
        'campo', 'O_QUE_O_AGENTE_FAZ',
        'perguntaSugerida', 'Antes de cadastrar qualquer coisa: o que você quer que eu faça pelas suas clientes? Posso só responder dúvida de preço e horário, ou também marcar o horário delas na sua agenda.') as item
        from n where not coalesce(n.escopo_respondido, false)
      union all
      select 10, jsonb_build_object(
        'campo', 'UNIDADE',
        'perguntaSugerida', 'Como se chama o seu salão, e qual o endereço completo? Rua, número, bairro, cidade e estado.')
        from n where coalesce(n.escopo_respondido, false)
                 and (n.unidade_nome is null or not n.tem_endereco)
      union all
      select 20, jsonb_build_object(
        'campo', 'HORARIOS',
        'perguntaSugerida', 'Que dias e horários o salão atende?')
        from n where coalesce(n.escopo_respondido, false) and n.horarios = 0
      union all
      select 30, jsonb_build_object(
        'campo', 'PROFISSIONAIS',
        'perguntaSugerida', 'Quem atende no salão? Me fala os nomes.')
        from n where coalesce(n.escopo_respondido, false) and n.profissionais = 0
      union all
      -- Disponibilidade so importa para quem vai marcar horario. Cobrar isso
      -- de um salao que so quer responder e cobrar cadastro que nunca sera
      -- lido.
      select 35, jsonb_build_object(
        'campo', 'DISPONIBILIDADE',
        'perguntaSugerida', 'Falta dizer como ' || n.sem_disponibilidade ||
          ' trabalha: no horário do salão, em dias próprios, ou sem dia fixo? Sem isso ninguém consegue marcar com ela.')
        from n where coalesce(n.escopo_respondido, false) and n.marca_horario
                 and n.sem_disponibilidade is not null
      union all
      select 40, jsonb_build_object(
        'campo', 'SERVICOS',
        'perguntaSugerida', 'Quais serviços você faz? Pode falar do jeito que você fala com as clientes.')
        from n where coalesce(n.escopo_respondido, false) and n.servicos = 0
      union all
      select 50, jsonb_build_object(
        'campo', 'PRECOS',
        'perguntaSugerida', 'Faltam preços em alguns serviços. Quanto fica cada um?')
        from n where coalesce(n.escopo_respondido, false) and n.servicos_sem_preco > 0
      union all
      select 60, jsonb_build_object(
        'campo', 'REGRAS',
        'perguntaSugerida', 'Tem alguma regra sua que a atendente precisa saber? Do jeito que você diria.')
        from n where coalesce(n.escopo_respondido, false) and n.regras = 0
      union all
      select 70, jsonb_build_object(
        'campo', 'WHATSAPP',
        'perguntaSugerida', 'Falta ligar o WhatsApp do salão. Quer que eu te mande o passo a passo?')
        from n where coalesce(n.escopo_respondido, false) and n.canais = 0
      union all
      select 80, jsonb_build_object(
        'campo', 'PUBLICAR',
        'perguntaSugerida', 'Está tudo cadastrado. Quer que eu publique para a atendente começar a usar?')
        from n where coalesce(n.escopo_respondido, false)
                 and n.canais > 0 and n.servicos > 0 and n.servicos_sem_preco = 0
                 and (not n.marca_horario or n.sem_disponibilidade is null)
                 and not n.publicado
    ) itens
  )
  select jsonb_build_object(
    'negocio',           (select t.display_name from app.tenants t where t.id = p_tenant_id),
    'unidade',           n.unidade_nome,
    'temEndereco',       n.tem_endereco,
    'publicado',         n.publicado,
    'rascunhoRev',       n.rascunho_rev,
    'escopoRespondido',  coalesce(n.escopo_respondido, false),
    'marcaHorario',      n.marca_horario,
    'horarios',          n.horarios,
    'profissionais',     n.profissionais,
    'semDisponibilidade',n.sem_disponibilidade,
    'servicos',          n.servicos,
    'servicosSemPreco',  n.servicos_sem_preco,
    'regras',            n.regras,
    'artes',             n.artes,
    'whatsappConectado', n.canais > 0,
    'falta',             (select lista from falta)
  ) from n;
$function$;

-- ---------------------------------------------------------------------------
-- O MANUAL.
-- ---------------------------------------------------------------------------

update app.agent_prompt_blocks
   set body = replace(
         body,
         '`registrar_identidade` — o nome do salão e o endereço.',
         '`definir_o_que_o_agente_faz` — a PRIMEIRA coisa da conversa. Só depois dela o resto faz sentido.

`registrar_identidade` — o nome do salão e o endereço.'),
       updated_at = statement_timestamp()
 where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER'
   and body not like '%definir_o_que_o_agente_faz%';

insert into app.agent_prompt_blocks (agent, code, title, body, position, status)
values ('DONO', 'EDDY_A_PRIMEIRA_PERGUNTA', 'A primeira pergunta é para que ele quer o agente',
$txt$COMECE PERGUNTANDO PARA QUE ELE QUER VOCÊ
Antes de nome de salão, antes de serviço, antes de qualquer cadastro: pergunte o que ele quer que você faça pelas clientes dele.

São dois tamanhos, e é assim que se explica:

- **só responder** — tirar dúvida de preço, horário, endereço, o que o salão faz, e chamar ele quando for coisa que só ele resolve.
- **responder e marcar** — tudo isso e mais: consultar a agenda e marcar o horário da cliente.

Quem escolher marcar, pergunte também: quer pedir um sinal para confirmar o horário? Quer regra de cancelamento? As duas só existem para quem marca.

Se ele perguntar por lembrete de véspera: diga que ainda não dá, que está sendo liberado, e que você avisa quando estiver pronto. Não prometa data.

POR QUE ISSO VEM PRIMEIRO, E NÃO DEPOIS: a resposta muda o que você vai perguntar. Para quem só quer responder, você não pergunta quem trabalha em que dia, nem quanto tempo o produto fica agindo — são coisas que só servem para encaixar horário. Perguntar assim mesmo faz ele preencher meia hora de cadastro que nunca vai ser lido, e é assim que dono desiste no meio.

Uma coisa por mensagem, como sempre. Esta pergunta também.$txt$, 25, 'ACTIVE')
on conflict (code) do update
   set agent = excluded.agent, title = excluded.title, body = excluded.body,
       position = excluded.position, status = 'ACTIVE', updated_at = statement_timestamp();
