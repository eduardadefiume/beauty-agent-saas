-- O OFICIO SAI DO SALAO, O PRECO DEIXA DE SER UM NUMERO SO,
-- E O CUSTO PASSA A DIZER DE QUAL AGENTE ELE VEIO.
--
-- Tres descobertas do teste de 18 a 20/09 com a dona do piloto.
--
-- 1. AS REGRAS DE OFICIO ESTAVAM PRESAS NO TENANT.
--    Das 47 politicas do salao, sete nao sao deste salao: "duas quimicas no
--    mesmo dia, nao", "botox antes de descoloracao se anula", "cabelo quebrando
--    nao recebe quimica". Isso e verdade em qualquer salao do Brasil. Estavam
--    em app.agent_policies, que e por tenant -- ou seja, o salao numero dois ia
--    ter que descobrir sozinho, ou pior, nao ia, e ia queimar o cabelo de uma
--    cliente. Vao para app.product_rules, que e do produto.
--
-- 2. PRECO QUE NAO E UM NUMERO SO NAO CABIA EM LUGAR NENHUM.
--    A dona disse "coloracao: raiz 160, raiz com muito cabelo 180, cabelo todo
--    220". O Eddy respondeu "Anotei" os tres -- e so o 160 entrou, porque
--    SERVICO_PRECO aceita um numero. Os outros dois sumiram em silencio e ele
--    disse que tinha gravado.
--    Mesma familia: "a partir de 450" e "a partir de 200" viraram preco fechado.
--    Uma cliente que quer o cabelo todo seria cotada em 160. Sessenta reais de
--    erro dito para cliente real -- a mesma classe de falha que derrubou o
--    piloto em 16/09, voltando por uma porta nova.
--
-- 3. O CUSTO NAO DIZIA DE QUEM ERA.
--    app.agent_usage juntava o Eddy (que configura, custo de UMA VEZ por salao)
--    com a atendente (que atende, custo de TODO MES). Sao dois precos
--    diferentes do produto -- taxa de setup e mensalidade -- e sem separar nao
--    da para calcular nenhum dos dois.
--
-- NAO ENTRA AQUI: fazer o agente das clientes LER as variacoes. O snapshot ja
-- as carrega, mas app.build_agent_context as descarta ao montar o catalogo.
-- Mexer nisso e cirurgia no caminho quente e vai em migration propria. Ate la o
-- dado fica certo e o agente continua sem ver -- o que nao faz mal porque ele
-- esta pausado e o rascunho 45 nao foi publicado.

-- ---------------------------------------------------------------------------
-- 1. O OFICIO VIRA CONHECIMENTO DO PRODUTO
-- ---------------------------------------------------------------------------
insert into app.product_rules (code, subject, title, statement, explains, position, status)
values
  ('QUIMICA_NAO_SAI_COM_O_TEMPO', 'QUIMICA',
   'Química não sai do cabelo com o tempo',
   'Progressiva, formol e alisamento não vão embora sozinhos. Saem com o crescimento e com o corte, e só. Então "faz dois anos que não faço" diz quando ela parou, não diz que o fio está livre. Cabelo mais longo pode carregar resquício de uma química antiga, e é por isso que o teste de mecha existe. Nunca diga à cliente que a química já saiu, que o cabelo está limpo ou que não tem mais nada: quem responde isso é a avaliação, não a conta de anos.',
   'Vale para qualquer salão: é química do fio, não política de negócio.', 100, 'ACTIVE'),

  ('DUAS_QUIMICAS_NO_MESMO_DIA_NAO', 'QUIMICA',
   'Duas químicas no mesmo dia, não',
   'Quando ela pedir dois procedimentos químicos juntos, você recusa e explica curto: "não indico, muita química em um dia só". Marca em dias separados. Vale para luzes com progressiva, coloração com alisamento, e qualquer combinação de duas químicas pesadas.',
   'Risco técnico ao fio. Nenhum salão deveria precisar descobrir isso sozinho.', 101, 'ACTIVE'),

  ('BOTOX_ANTES_DE_DESCOLORACAO', 'QUIMICA',
   'Botox antes de descoloração atrapalha',
   'Se ela quer clarear e fez botox há pouco, avisa: o botox recente dificulta a descoloração, e a descoloração tira o efeito do botox. Um anula o outro. Nesse caso a ordem certa é clarear primeiro e tratar depois.',
   'Incompatibilidade entre procedimentos. Vale em qualquer lugar.', 102, 'ACTIVE'),

  ('CABELO_QUEBRANDO_NAO_RECEBE_QUIMICA', 'CABELO',
   'Cabelo quebrando, você não faz química',
   'Se a cliente falar que o cabelo está caindo, quebrando ou muito danificado, você não agenda química. Fala assim: "se já apresenta quebra, melhor não fazer. Precisa fortalecer o cabelo primeiro." E oferece tratamento: cronograma, hidratação ou reconstrução. Recusar hoje para vender química daqui a um mês vale mais que estragar o cabelo dela.',
   'Segurança do fio, e também o melhor negócio a longo prazo.', 103, 'ACTIVE'),

  ('COURO_MACHUCADO_ADIA', 'CABELO',
   'Couro cabeludo machucado, adia',
   'Se ela disser que está com o couro ferido, irritado ou com ferida, não faz selante nem alisamento: "não pode fazer não, irá arder porque o couro está machucado". Remarca para quando estiver curado.',
   'Segurança da pessoa. Não é preferência de salão.', 104, 'ACTIVE'),

  ('DURABILIDADE_SE_EXPLICA_PELA_RAIZ', 'COR',
   'Durabilidade se explica pela raiz',
   'Quando perguntarem quanto tempo dura cor, gloss ou retoque, a resposta é "conforme a raiz cresce". Não invente prazo em meses: o que define é o crescimento do cabelo dela, e isso varia de pessoa para pessoa.',
   'Impede o agente de inventar prazo, que é onde ele mais mente.', 105, 'ACTIVE'),

  ('QUEM_DIAGNOSTICA_E_O_TESTE', 'COR',
   'Quem diagnostica é o teste, não a conversa',
   'Tudo que depende de ver o fio (se aguenta, até que tom dá para ir, se ainda tem química antiga, se precisa de correção) se resolve na avaliação com o teste de mecha. Na conversa você só recolhe o que a cliente sabe contar e leva ela até o horário. Não antecipe resultado, não tranquilize com garantia técnica.',
   'A regra que impede promessa técnica por WhatsApp.', 106, 'ACTIVE')
on conflict (code) do nothing;

-- As copias no tenant saem de cena, mas nao somem: ARCHIVED e o mesmo que o
-- onboarding_undo faz, e o agente so le ACTIVE.
update app.agent_policies p
   set status = 'ARCHIVED', updated_at = statement_timestamp()
  from app.tenants t
 where p.tenant_id = t.id
   and t.slug = 'piloto-eduarda'
   and p.status = 'ACTIVE'
   and p.title in (
     'Química não sai do cabelo com o tempo',
     'Duas químicas no mesmo dia, não',
     'Botox antes de descoloração atrapalha',
     'Cabelo quebrando, você não faz química',
     'Couro cabeludo machucado, adia',
     'Durabilidade se explica pela raiz',
     'Quem diagnostica é o teste, não a conversa'
   );

-- ---------------------------------------------------------------------------
-- 2. PRECO PODE SER PISO, E NAO SO NUMERO FECHADO
-- ---------------------------------------------------------------------------
alter table app.services
  add column if not exists price_is_floor boolean not null default false;

comment on column app.services.price_is_floor is
  'true quando o valor e "a partir de". Existe porque o dono disse "a partir de 450" e o sistema gravou 450 fechado -- e a atendente cotaria 450 como se fosse o final.';

-- ---------------------------------------------------------------------------
-- 3. OS VERBOS QUE FALTAVAM AO EDDY
-- ---------------------------------------------------------------------------
create or replace function app.onboarding_definir_preco(
  p_tenant_id   uuid,
  p_service_id  uuid,
  p_preco_reais numeric,
  p_e_piso      boolean default false
)
returns jsonb
language plpgsql security definer set search_path to ''
as $fn$
declare v_alvo uuid; v_nome text; v_antes jsonb;
begin
  if p_preco_reais is null or p_preco_reais <= 0 or p_preco_reais > 100000 then
    return jsonb_build_object('ok', false, 'reason', 'PRECO_FORA_DE_FAIXA');
  end if;

  v_alvo := app.servico_no_rascunho(p_tenant_id, p_service_id);
  if v_alvo is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO_NO_RASCUNHO');
  end if;

  select jsonb_build_object('base_price_minor', s.base_price_minor,
                            'price_is_floor', s.price_is_floor), s.name
    into v_antes, v_nome
    from app.services s where s.id = v_alvo;

  update app.services
     set base_price_minor = round(p_preco_reais * 100)::integer,
         price_is_floor   = coalesce(p_e_piso, false),
         updated_at       = statement_timestamp()
   where id = v_alvo and tenant_id = p_tenant_id;

  return jsonb_build_object('ok', true, 'servico', v_nome,
                            'ehPiso', coalesce(p_e_piso, false), 'antes', v_antes);
end;
$fn$;

revoke all on function app.onboarding_definir_preco(uuid, uuid, numeric, boolean) from public, anon, authenticated;
grant execute on function app.onboarding_definir_preco(uuid, uuid, numeric, boolean) to service_role;

-- Uma variacao por preco diferente. E o lugar onde as tres coloracoes cabem.
create or replace function app.onboarding_criar_variacao(
  p_tenant_id   uuid,
  p_service_id  uuid,
  p_nome        text,
  p_preco_reais numeric
)
returns jsonb
language plpgsql security definer set search_path to ''
as $fn$
declare v_alvo uuid; v_rasc uuid; v_nome text := nullif(trim(coalesce(p_nome,'')),''); v_id uuid;
begin
  if v_nome is null or length(v_nome) < 2 or length(v_nome) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_DA_VARIACAO_FORA_DE_FAIXA');
  end if;
  if p_preco_reais is null or p_preco_reais <= 0 or p_preco_reais > 100000 then
    return jsonb_build_object('ok', false, 'reason', 'PRECO_FORA_DE_FAIXA');
  end if;

  v_alvo := app.servico_no_rascunho(p_tenant_id, p_service_id);
  if v_alvo is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO_NO_RASCUNHO');
  end if;

  select s.configuration_draft_id into v_rasc from app.services s where s.id = v_alvo;

  if exists (select 1 from app.service_variations v
              where v.service_id = v_alvo and lower(v.name) = lower(v_nome)
                and v.status = 'ACTIVE') then
    return jsonb_build_object('ok', false, 'reason', 'VARIACAO_JA_EXISTE');
  end if;

  insert into app.service_variations
    (tenant_id, configuration_draft_id, service_id, name, price_minor, status)
  values
    (p_tenant_id, v_rasc, v_alvo, v_nome, round(p_preco_reais * 100)::integer, 'ACTIVE')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'variacaoId', v_id, 'nome', v_nome);
end;
$fn$;

revoke all on function app.onboarding_criar_variacao(uuid, uuid, text, numeric) from public, anon, authenticated;
grant execute on function app.onboarding_criar_variacao(uuid, uuid, text, numeric) to service_role;

-- O Eddy conhece o servico pelo NOME, nao pelo id: quem tem id e a pendencia,
-- e remover servico nao nasce de pendencia nenhuma.
create or replace function app.onboarding_desativar_servico_por_nome(
  p_tenant_id uuid, p_nome text
)
returns jsonb
language plpgsql security definer set search_path to ''
as $fn$
declare v_origem uuid; v_id uuid; v_nome text := nullif(trim(coalesce(p_nome,'')),''); v_quantos int;
begin
  if v_nome is null then
    return jsonb_build_object('ok', false, 'reason', 'NOME_NAO_INFORMADO');
  end if;

  select d.id into v_origem
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id
   order by (d.status = 'DRAFT') desc, d.revision desc limit 1;

  select count(*) into v_quantos
    from app.services s
   where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_origem
     and s.status = 'ACTIVE' and lower(s.name) = lower(v_nome);

  if v_quantos = 0 then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_ENCONTRADO', 'procurado', v_nome);
  end if;
  if v_quantos > 1 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_AMBIGUO', 'procurado', v_nome);
  end if;

  select s.id into v_id
    from app.services s
   where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_origem
     and s.status = 'ACTIVE' and lower(s.name) = lower(v_nome);

  return app.onboarding_desativar_servico(p_tenant_id, v_id);
end;
$fn$;

revoke all on function app.onboarding_desativar_servico_por_nome(uuid, text) from public, anon, authenticated;
grant execute on function app.onboarding_desativar_servico_por_nome(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. PEDIDO QUE O EDDY NAO ALCANCA VIRA ALERTA, NAO SILENCIO
-- ---------------------------------------------------------------------------
create or replace function app.recado_do_problema(p_kind text)
returns text language sql immutable
as $fn$
  select case p_kind
    when 'SEM_CREDITO'            then 'O agente parou de responder: acabou o crédito da IA. Ele volta sozinho assim que você recarregar.'
    when 'CHAVE_DA_IA_INVALIDA'   then 'O agente parou de responder: a chave da IA foi recusada. Precisa ser trocada na configuração.'
    when 'IA_OCUPADA'             then 'A IA está sobrecarregada e o agente está demorando para responder. Costuma passar sozinho em alguns minutos.'
    when 'TOKEN_DO_WHATSAPP'      then 'O WhatsApp recusou o acesso do agente. O token do número precisa ser renovado.'
    when 'AGENTE_FALHANDO'        then 'O agente está falhando seguido em pelo menos uma conversa. Vale olhar as conversas paradas.'
    when 'PEDIDO_FORA_DO_ALCANCE' then 'Um dono pediu ao Eddy algo que o produto ainda não sabe fazer. Vale olhar: ou vira funcionalidade, ou vira resposta pronta.'
    else 'O agente encontrou um problema repetido.'
  end;
$fn$;

create or replace function app.registrar_pedido_fora_do_alcance(
  p_conversation_id uuid,
  p_pedido_do_dono  text,
  p_motivo_do_eddy  text
)
returns jsonb
language plpgsql security definer set search_path to ''
as $fn$
declare v_tenant uuid;
begin
  select c.tenant_id into v_tenant from app.crm_conversations c where c.id = p_conversation_id;
  if v_tenant is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSA_NAO_EXISTE');
  end if;

  perform app.raise_agent_alert(
    v_tenant, 'PEDIDO_FORA_DO_ALCANCE',
    left(coalesce(p_pedido_do_dono, ''), 400) || ' || ' || left(coalesce(p_motivo_do_eddy, ''), 300));

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function app.registrar_pedido_fora_do_alcance(uuid, text, text) from public, anon, authenticated;
grant execute on function app.registrar_pedido_fora_do_alcance(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. O QUE O DONO DISSE E O EDDY NAO SOUBE ARQUIVAR
--
-- Aprender e livre; escrever continua fechado; promover e revisado. Esta tabela
-- e o "livre": tudo que o dono disser e nao couber em destino nenhum fica aqui,
-- com as palavras dele. Nada se perde. O que e revisado e so a PROMOCAO -- se
-- aquilo vira pergunta para todos os saloes ou fica sendo coisa deste.
-- ---------------------------------------------------------------------------
create table if not exists app.conhecimento_nao_classificado (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references app.tenants(id) on delete cascade,
  conversation_id  uuid,
  palavras_do_dono text not null,
  palpite_modulo   text,
  palpite_escopo   text check (palpite_escopo in ('DESTE_NEGOCIO', 'DO_OFICIO', 'UNIVERSAL')),
  porque_nao_coube text,
  status           text not null default 'NOVO'
                   check (status in ('NOVO', 'VIROU_REGRA', 'VIROU_PERGUNTA', 'DESCARTADO')),
  revisado_por     text,
  revisado_em      timestamptz,
  created_at       timestamptz not null default statement_timestamp()
);

alter table app.conhecimento_nao_classificado enable row level security;

create index if not exists conhecimento_nao_classificado_novos_idx
  on app.conhecimento_nao_classificado (status, created_at desc) where status = 'NOVO';

comment on table app.conhecimento_nao_classificado is
  'O que o dono disse e o Eddy nao soube onde arquivar. Gravar e automatico e gratuito; promover para pergunta global e que e revisado. E o que impede o produto de aprender uma coisa so e esquecer as outras dez.';

create or replace function app.registrar_conhecimento_solto(
  p_tenant_id       uuid,
  p_conversation_id uuid,
  p_palavras        text,
  p_modulo          text default null,
  p_escopo          text default null,
  p_porque          text default null
)
returns jsonb
language plpgsql security definer set search_path to ''
as $fn$
declare v_id uuid;
begin
  if coalesce(trim(p_palavras), '') = '' or length(trim(p_palavras)) < 5 then
    return jsonb_build_object('ok', false, 'reason', 'PALAVRAS_VAZIAS');
  end if;

  insert into app.conhecimento_nao_classificado
    (tenant_id, conversation_id, palavras_do_dono, palpite_modulo, palpite_escopo, porque_nao_coube)
  values
    (p_tenant_id, p_conversation_id, left(trim(p_palavras), 4000),
     nullif(trim(coalesce(p_modulo, '')), ''),
     case when p_escopo in ('DESTE_NEGOCIO','DO_OFICIO','UNIVERSAL') then p_escopo end,
     left(coalesce(p_porque, ''), 500))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$fn$;

revoke all on function app.registrar_conhecimento_solto(uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function app.registrar_conhecimento_solto(uuid, uuid, text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 6. O CUSTO PASSA A DIZER DE QUAL AGENTE VEIO
-- ---------------------------------------------------------------------------
alter table app.agent_usage
  add column if not exists agente text
  check (agente is null or agente in ('CLIENTE', 'DONO'));

comment on column app.agent_usage.agente is
  'DONO = o Eddy configurando (custo de uma vez por salao, entra na taxa de setup). CLIENTE = a atendente (custo recorrente, entra na mensalidade). Sem isto os dois precos do produto sao incalculaveis.';

-- Backfill pelo que da para saber: conversa do dono e conversa do dono.
update app.agent_usage u
   set agente = case when app.conversa_e_do_dono(u.conversation_id) then 'DONO' else 'CLIENTE' end
 where u.agente is null and u.conversation_id is not null;

create or replace function public.agent_record_usage(
  p_tenant_id uuid, p_conversation_id uuid, p_modelo text, p_esforco text,
  p_voltas integer, p_input integer, p_output integer, p_cache_write integer,
  p_cache_read integer, p_desfecho text, p_agente text default null
)
returns jsonb
language plpgsql security definer set search_path to ''
as $fn$
declare
  v_p app.model_prices%rowtype;
  v_micro bigint;
  v_agente text;
begin
  select * into v_p from app.model_prices where modelo = p_modelo;

  v_micro := case when v_p.modelo is null then 0 else round(
      coalesce(p_input,0)       * v_p.input_por_mtok
    + coalesce(p_output,0)      * v_p.output_por_mtok
    + coalesce(p_cache_write,0) * v_p.cache_write_por_mtok
    + coalesce(p_cache_read,0)  * v_p.cache_read_por_mtok
  ) end;

  -- Se quem chamou nao disse, o banco deduz pela conversa. Deduzir e melhor
  -- que deixar nulo: nulo vira linha que nao entra em conta nenhuma.
  v_agente := case
    when p_agente in ('CLIENTE','DONO') then p_agente
    when p_conversation_id is not null and app.conversa_e_do_dono(p_conversation_id) then 'DONO'
    when p_conversation_id is not null then 'CLIENTE'
    else null end;

  insert into app.agent_usage
    (tenant_id, conversation_id, modelo, esforco, voltas,
     input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
     custo_microdolares, desfecho, agente)
  values
    (p_tenant_id, p_conversation_id, p_modelo, p_esforco, greatest(coalesce(p_voltas,1),1),
     coalesce(p_input,0), coalesce(p_output,0), coalesce(p_cache_write,0), coalesce(p_cache_read,0),
     v_micro, p_desfecho, v_agente);

  return jsonb_build_object('ok', true, 'microdolares', v_micro,
                            'agente', v_agente, 'semPreco', v_p.modelo is null);
end;
$fn$;

revoke all on function public.agent_record_usage(uuid,uuid,text,text,integer,integer,integer,integer,integer,text,text)
  from public, anon, authenticated;
grant execute on function public.agent_record_usage(uuid,uuid,text,text,integer,integer,integer,integer,integer,text,text)
  to service_role;

-- A conta que decide o preco do produto.
create or replace function app.custo_por_agente(p_tenant_id uuid default null)
returns jsonb
language sql stable security definer set search_path to ''
as $fn$
  select jsonb_build_object(
    'onboarding', (
      select jsonb_build_object(
        'turnos', count(*),
        'dolares', round(coalesce(sum(custo_microdolares),0)/1000000.0, 4),
        'porTurno', case when count(*)=0 then 0
                    else round(coalesce(sum(custo_microdolares),0)/1000000.0/count(*), 5) end,
        'saloes', count(distinct tenant_id),
        'porSalao', case when count(distinct tenant_id)=0 then 0
                    else round(coalesce(sum(custo_microdolares),0)/1000000.0
                               /count(distinct tenant_id), 4) end)
        from app.agent_usage
       where agente = 'DONO' and (p_tenant_id is null or tenant_id = p_tenant_id)),
    'atendimento', (
      select jsonb_build_object(
        'turnos', count(*),
        'dolares', round(coalesce(sum(custo_microdolares),0)/1000000.0, 4),
        'porTurno', case when count(*)=0 then 0
                    else round(coalesce(sum(custo_microdolares),0)/1000000.0/count(*), 5) end,
        'conversas', count(distinct conversation_id),
        'porConversa', case when count(distinct conversation_id)=0 then 0
                       else round(coalesce(sum(custo_microdolares),0)/1000000.0
                                  /count(distinct conversation_id), 5) end)
        from app.agent_usage
       where agente = 'CLIENTE' and (p_tenant_id is null or tenant_id = p_tenant_id)),
    'semClassificacao', (
      select count(*) from app.agent_usage
       where agente is null and (p_tenant_id is null or tenant_id = p_tenant_id))
  );
$fn$;

revoke all on function app.custo_por_agente(uuid) from public, anon, authenticated;
grant execute on function app.custo_por_agente(uuid) to service_role;

create or replace function public.custo_por_agente(p_tenant_id uuid default null)
returns jsonb language sql stable security definer set search_path to ''
as $fn$ select app.custo_por_agente(p_tenant_id); $fn$;

revoke all on function public.custo_por_agente(uuid) from public, anon, authenticated;
grant execute on function public.custo_por_agente(uuid) to service_role;

notify pgrst, 'reload schema';
