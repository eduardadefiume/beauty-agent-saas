-- CIDADE SEM ESTADO NAO E ENDERECO.
--
-- 23/09/2026, pedido da dona do produto: "pode ser que eu venda a outros
-- estados e nao somente SP, e tem cidades com o mesmo nome em estados
-- diferentes".
--
-- Ela esta certa e o exemplo estava na frente da gente: no teste de hoje o
-- salao ficava em JARDINOPOLIS -- que existe em Sao Paulo E em Goias. O
-- endereco gravado de manha ("Rua Rui Barbosa, 323, Centro, Jardinopolis")
-- nao aponta um lugar no mundo.
--
-- O ESTADO VIRA CAMPO, NAO PEDACO DE FRASE. Daria para so pedir "mande a UF no
-- fim" e guardar tudo no mesmo texto. Seria pior: texto livre nao da para
-- conferir, e a hora de descobrir que faltou e quando a cliente esta indo para
-- o salao errado. Campo separado, validado contra as 27 UFs, recusa na hora.
--
-- Como `address_json` ja e jsonb, o formato passa a ser:
--     {"texto": "Rua Rui Barbosa, 323, Centro, Jardinopolis", "uf": "SP"}

-- ---------------------------------------------------------------------------
-- 1. A PERGUNTA DO CATALOGO PASSA A PEDIR O ESTADO.
--
-- Funcao recriada inteira porque SQL nao edita string dentro de funcao. A
-- UNICA diferenca em relacao ao que estava no banco e a `perguntaSugerida` do
-- campo UNIDADE.
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
  n as (
    select
      (select name from unidade)                                              as unidade_nome,
      coalesce((select coalesce(address_json, '{}'::jsonb) <> '{}'::jsonb from unidade), false) as tem_endereco,
      coalesce((select active_configuration_version_id is not null from unidade), false)        as publicado,
      (select revision from rascunho)                                         as rascunho_rev,
      (select count(*) from app.operating_hours h
        where h.tenant_id = p_tenant_id
          and h.configuration_draft_id = (select id from rascunho))            as horarios,
      (select count(*) from app.team_members m
        where m.tenant_id = p_tenant_id
          and m.configuration_draft_id = (select id from rascunho)
          and m.status = 'ACTIVE')                                             as profissionais,
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
      select 1 as ordem, jsonb_build_object(
        'campo', 'UNIDADE',
        'perguntaSugerida', 'Como se chama o seu salão, e qual o endereço completo? Rua, número, bairro, cidade e estado.') as item
        from n where n.unidade_nome is null or not n.tem_endereco
      union all
      select 2, jsonb_build_object(
        'campo', 'HORARIOS',
        'perguntaSugerida', 'Que dias e horários o salão atende?')
        from n where n.horarios = 0
      union all
      select 3, jsonb_build_object(
        'campo', 'PROFISSIONAIS',
        'perguntaSugerida', 'Quem atende no salão? Me fala os nomes.')
        from n where n.profissionais = 0
      union all
      select 4, jsonb_build_object(
        'campo', 'SERVICOS',
        'perguntaSugerida', 'Quais serviços você faz? Pode falar do jeito que você fala com as clientes.')
        from n where n.servicos = 0
      union all
      select 5, jsonb_build_object(
        'campo', 'PRECOS',
        'perguntaSugerida', 'Faltam preços em alguns serviços. Quanto fica cada um?')
        from n where n.servicos_sem_preco > 0
      union all
      select 6, jsonb_build_object(
        'campo', 'REGRAS',
        'perguntaSugerida', 'Tem alguma regra sua que a atendente precisa saber? Do jeito que você diria.')
        from n where n.regras = 0
      union all
      select 7, jsonb_build_object(
        'campo', 'WHATSAPP',
        'perguntaSugerida', 'Falta ligar o WhatsApp do salão. Quer que eu te mande o passo a passo?')
        from n where n.canais = 0
      union all
      select 8, jsonb_build_object(
        'campo', 'PUBLICAR',
        'perguntaSugerida', 'Está tudo cadastrado. Quer que eu publique para a atendente começar a usar?')
        from n where n.canais > 0 and n.servicos > 0 and n.servicos_sem_preco = 0 and not n.publicado
    ) itens
  )
  select jsonb_build_object(
    'negocio',           (select t.display_name from app.tenants t where t.id = p_tenant_id),
    'unidade',           n.unidade_nome,
    'temEndereco',       n.tem_endereco,
    'publicado',         n.publicado,
    'rascunhoRev',       n.rascunho_rev,
    'horarios',          n.horarios,
    'profissionais',     n.profissionais,
    'servicos',          n.servicos,
    'servicosSemPreco',  n.servicos_sem_preco,
    'regras',            n.regras,
    'artes',             n.artes,
    'whatsappConectado', n.canais > 0,
    'falta',             (select lista from falta)
  ) from n;
$function$;

-- ---------------------------------------------------------------------------
-- 2. A FERRAMENTA PASSA A EXIGIR A UF.
--
-- A versao de 3 argumentos sai de cena. Deixar as duas conviveria com o Eddy
-- escolhendo a antiga e gravando endereco sem estado -- exatamente o que esta
-- migration existe para impedir.
-- ---------------------------------------------------------------------------

drop function if exists public.onboarding_registrar_identidade(uuid, text, text);
drop function if exists app.onboarding_registrar_identidade(uuid, text, text);

create or replace function app.onboarding_registrar_identidade(
  p_tenant_id uuid,
  p_nome      text,
  p_endereco  text default null,
  p_uf        text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome     text := nullif(trim(coalesce(p_nome, '')), '');
  v_endereco text := nullif(trim(coalesce(p_endereco, '')), '');
  v_uf       text := upper(nullif(trim(coalesce(p_uf, '')), ''));
  v_ufs      text[] := array['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG',
                             'PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'];
  v_unidade  uuid;
  v_antes    text;
begin
  if v_nome is null or length(v_nome) < 2 or length(v_nome) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_FORA_DE_FAIXA');
  end if;

  if v_endereco is not null then
    -- Endereco pela metade e pior que endereco nenhum: a cliente sai para a
    -- rua com ele.
    if length(v_endereco) < 10 then
      return jsonb_build_object('ok', false, 'reason', 'ENDERECO_CURTO_DEMAIS');
    end if;

    -- E cidade sem estado nao aponta lugar nenhum: Jardinopolis existe em SP
    -- e em GO, e o salao do teste fica numa delas.
    if v_uf is null then
      return jsonb_build_object('ok', false, 'reason', 'FALTA_O_ESTADO');
    end if;
    if not (v_uf = any(v_ufs)) then
      return jsonb_build_object('ok', false, 'reason', 'ESTADO_INVALIDO', 'recebi', v_uf);
    end if;
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
                          else jsonb_build_object('texto', v_endereco, 'uf', v_uf)
                        end,
         updated_at   = statement_timestamp()
   where id = v_unidade;

  return jsonb_build_object(
    'ok', true,
    'salao', v_nome,
    'endereco', v_endereco,
    'uf', v_uf,
    'antes', jsonb_build_object('nome', v_antes)
  );
end;
$fn$;

comment on function app.onboarding_registrar_identidade(uuid, text, text, text) is
  'Grava nome, endereco e UF do salao. A UF e obrigatoria quando ha endereco: cidade sem estado nao aponta lugar nenhum.';
revoke all on function app.onboarding_registrar_identidade(uuid, text, text, text) from public, anon, authenticated;
grant execute on function app.onboarding_registrar_identidade(uuid, text, text, text) to service_role;

-- E a porta publica, sem a qual nada disso existe para o agente.
create or replace function public.onboarding_registrar_identidade(
  p_tenant_id uuid, p_nome text, p_endereco text default null, p_uf text default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_registrar_identidade(p_tenant_id, p_nome, p_endereco, p_uf); $$;
revoke all on function public.onboarding_registrar_identidade(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.onboarding_registrar_identidade(uuid, text, text, text) to service_role;
