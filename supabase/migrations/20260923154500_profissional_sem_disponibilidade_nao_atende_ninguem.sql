-- PROFISSIONAL SEM DISPONIBILIDADE NAO ATENDE NINGUEM.
--
-- 23/09/2026. A dona reparou que a Duda tinha sido cadastrada como horario
-- FIXO, sendo que ela "vem a cada 15 dias e anota na agenda os dias que pode
-- vir". Fui consertar isso e achei coisa pior: nenhuma das tres profissionais
-- tinha disponibilidade nenhuma.
--
--   Duda     FIXED   0 dias semanais   0 datas avulsas
--   Eduarda  FIXED   0 dias semanais   0 datas avulsas
--   Karen    FIXED   0 dias semanais   0 datas avulsas
--
-- O salao PARECIA configurado -- 10 servicos, 5 dias de horario, equipe
-- cadastrada -- e nao dava para marcar com ninguem.
--
-- A CAUSA: `onboarding_criar_membro_equipe` criava a pessoa e parava ali. E a
-- agenda le a disponibilidade DA PESSOA, nao a do salao:
--
--   FIXED    so `member_availability`      (a semana dela)
--   DYNAMIC  so `member_dynamic_shifts`    (as datas que ela marcar)
--   HYBRID   as duas
--
-- Sem linha em nenhuma das duas, a janela dela e vazia e ela nunca aparece
-- como opcao. Nada quebra, nada avisa: o salao so nunca tem horario.
--
-- O VOCABULARIO E O DO DONO, NAO O DO BANCO. Ninguem diz "a Karen e HYBRID".
-- Diz "a Karen trabalha no horario do salao" ou "a Duda vem sem dia fixo".
-- Entao a ferramenta fala assim, e a traducao para FIXED/DYNAMIC acontece
-- aqui dentro:
--
--   IGUAL_AO_SALAO  trabalha nos dias e horarios do salao (o caso comum)
--   DIAS_PROPRIOS   tem a semana dela, diferente da do salao
--   SEM_DIA_FIXO    nao tem semana; avisa as datas quando sabe

-- ---------------------------------------------------------------------------
-- 1. O MOTOR: aplica a escolha, traduzindo para o modelo.
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_definir_disponibilidade(
  p_tenant_id       uuid,
  p_nome            text,
  p_disponibilidade text,
  p_dias            jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome      text := nullif(trim(coalesce(p_nome, '')), '');
  v_escolha   text := upper(nullif(trim(coalesce(p_disponibilidade, '')), ''));
  v_rascunho  uuid;
  v_membro    uuid;
  v_modo      text;
  v_item      jsonb;
  v_dia       integer;
  v_abre      time;
  v_fecha     time;
  v_copiados  integer := 0;
begin
  if v_nome is null then
    return jsonb_build_object('ok', false, 'reason', 'NOME_NAO_INFORMADO');
  end if;
  if v_escolha is null or v_escolha not in ('IGUAL_AO_SALAO','DIAS_PROPRIOS','SEM_DIA_FIXO') then
    return jsonb_build_object('ok', false, 'reason', 'DISPONIBILIDADE_INVALIDA');
  end if;

  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  select m.id into v_membro
    from app.team_members m
   where m.tenant_id = p_tenant_id
     and m.configuration_draft_id = v_rascunho
     and m.status = 'ACTIVE'
     and lower(m.name) = lower(v_nome)
   limit 1;

  if v_membro is null then
    return jsonb_build_object('ok', false, 'reason', 'PESSOA_NAO_ESTA_NA_EQUIPE', 'pessoa', v_nome);
  end if;

  v_modo := case v_escolha when 'SEM_DIA_FIXO' then 'DYNAMIC' else 'FIXED' end;

  -- Valida a semana ANTES de apagar o que existe, pela mesma razao de sempre:
  -- um dia errado no meio nao pode deixar a pessoa sem horario nenhum.
  if v_escolha = 'DIAS_PROPRIOS' then
    if p_dias is null or jsonb_typeof(p_dias) <> 'array' or jsonb_array_length(p_dias) = 0 then
      return jsonb_build_object('ok', false, 'reason', 'FALTAM_OS_DIAS_DELA');
    end if;
    for v_item in select * from jsonb_array_elements(p_dias) loop
      begin
        v_dia := (v_item->>'dia')::integer;
        v_abre := (v_item->>'abre')::time;
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
  end if;

  if v_escolha = 'IGUAL_AO_SALAO'
     and not exists (select 1 from app.operating_hours h
                      where h.tenant_id = p_tenant_id
                        and h.configuration_draft_id = v_rascunho) then
    -- Nao da para copiar o que nao existe. E a recusa diz o que perguntar.
    return jsonb_build_object(
      'ok', false, 'reason', 'SALAO_SEM_HORARIO',
      'pergunteAntes', 'Que dias e horários o salão atende?');
  end if;

  update app.team_members
     set availability_mode = v_modo::app.availability_mode,
         updated_at = statement_timestamp()
   where id = v_membro;

  delete from app.member_availability
   where tenant_id = p_tenant_id and configuration_draft_id = v_rascunho and member_id = v_membro;

  if v_escolha = 'IGUAL_AO_SALAO' then
    insert into app.member_availability (tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at)
    select p_tenant_id, v_rascunho, v_membro, h.weekday, h.starts_at, h.ends_at
      from app.operating_hours h
     where h.tenant_id = p_tenant_id and h.configuration_draft_id = v_rascunho;
    get diagnostics v_copiados = row_count;

  elsif v_escolha = 'DIAS_PROPRIOS' then
    for v_item in select * from jsonb_array_elements(p_dias) loop
      insert into app.member_availability (tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at)
      values (p_tenant_id, v_rascunho, v_membro,
              (v_item->>'dia')::integer, (v_item->>'abre')::time, (v_item->>'fecha')::time)
      on conflict do nothing;
      v_copiados := v_copiados + 1;
    end loop;

  else
    -- SEM_DIA_FIXO: a semana some de proposito. Ela so aparece nas datas que
    -- marcar, e enquanto nao marcar nenhuma nao e oferecida -- que e a
    -- verdade, nao uma falha.
    v_copiados := 0;
  end if;

  return jsonb_build_object(
    'ok', true, 'pessoa', v_nome, 'comoTrabalha', v_escolha,
    'modo', v_modo, 'diasGravados', v_copiados,
    'precisaMarcarDatas', v_escolha = 'SEM_DIA_FIXO'
  );
end;
$fn$;

comment on function app.onboarding_definir_disponibilidade(uuid, text, text, jsonb) is
  'Diz como a profissional trabalha, no vocabulario do dono, e traduz para availability_mode + member_availability. Sem isto a pessoa existe e nunca e oferecida.';
revoke all on function app.onboarding_definir_disponibilidade(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.onboarding_definir_disponibilidade(uuid, text, text, jsonb) to service_role;

create or replace function public.onboarding_definir_disponibilidade(
  p_tenant_id uuid, p_nome text, p_disponibilidade text, p_dias jsonb default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_definir_disponibilidade(p_tenant_id, p_nome, p_disponibilidade, p_dias); $$;
revoke all on function public.onboarding_definir_disponibilidade(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.onboarding_definir_disponibilidade(uuid, text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 2. A DATA AVULSA: "dia 5 ela vem das 9 as 17".
-- ---------------------------------------------------------------------------

create or replace function app.onboarding_marcar_dia_da_profissional(
  p_tenant_id uuid,
  p_nome      text,
  p_data      date,
  p_abre      time default null,
  p_fecha     time default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_nome     text := nullif(trim(coalesce(p_nome, '')), '');
  v_rascunho uuid;
  v_membro   uuid;
  v_modo     text;
  v_abre     time := p_abre;
  v_fecha    time := p_fecha;
begin
  if v_nome is null then
    return jsonb_build_object('ok', false, 'reason', 'NOME_NAO_INFORMADO');
  end if;
  if p_data is null then
    return jsonb_build_object('ok', false, 'reason', 'DATA_NAO_INFORMADA');
  end if;
  -- Data que ja passou nao abre horario nenhum, e aceitar em silencio faria a
  -- dona achar que marcou.
  if p_data < (statement_timestamp() at time zone 'America/Sao_Paulo')::date then
    return jsonb_build_object('ok', false, 'reason', 'DATA_NO_PASSADO', 'data', p_data);
  end if;

  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  select m.id, m.availability_mode::text into v_membro, v_modo
    from app.team_members m
   where m.tenant_id = p_tenant_id
     and m.configuration_draft_id = v_rascunho
     and m.status = 'ACTIVE'
     and lower(m.name) = lower(v_nome)
   limit 1;

  if v_membro is null then
    return jsonb_build_object('ok', false, 'reason', 'PESSOA_NAO_ESTA_NA_EQUIPE', 'pessoa', v_nome);
  end if;

  -- Data avulsa em quem e FIXED e ignorada pela agenda (ela so olha a semana).
  -- Gravar assim mesmo seria escrever uma linha que nao faz nada.
  if v_modo = 'FIXED' then
    return jsonb_build_object(
      'ok', false, 'reason', 'PESSOA_TEM_HORARIO_FIXO', 'pessoa', v_nome,
      'comoResolver', 'Se ela passou a vir sem dia fixo, mude como ela trabalha antes de marcar datas.');
  end if;

  -- Sem hora dita, vale o horario do salao naquele dia da semana.
  if v_abre is null or v_fecha is null then
    select h.starts_at, h.ends_at into v_abre, v_fecha
      from app.operating_hours h
     where h.tenant_id = p_tenant_id
       and h.configuration_draft_id = v_rascunho
       and h.weekday = extract(dow from p_data)::smallint
     order by h.starts_at
     limit 1;
  end if;

  if v_abre is null or v_fecha is null then
    return jsonb_build_object(
      'ok', false, 'reason', 'SEM_HORA_E_SALAO_FECHADO_NESSE_DIA', 'data', p_data,
      'comoResolver', 'Pergunte de que hora a que hora ela vem nesse dia.');
  end if;
  if v_abre >= v_fecha then
    return jsonb_build_object('ok', false, 'reason', 'HORARIO_INVERTIDO');
  end if;

  insert into app.member_dynamic_shifts (tenant_id, configuration_draft_id, member_id, shift_date, starts_at, ends_at)
  values (p_tenant_id, v_rascunho, v_membro, p_data, v_abre, v_fecha)
  on conflict do nothing;

  return jsonb_build_object(
    'ok', true, 'pessoa', v_nome, 'data', p_data,
    'abre', v_abre::text, 'fecha', v_fecha::text
  );
end;
$fn$;

comment on function app.onboarding_marcar_dia_da_profissional(uuid, text, date, time, time) is
  'Marca uma data em que a profissional sem dia fixo vem. Sem hora, herda o horario do salao naquele dia.';
revoke all on function app.onboarding_marcar_dia_da_profissional(uuid, text, date, time, time) from public, anon, authenticated;
grant execute on function app.onboarding_marcar_dia_da_profissional(uuid, text, date, time, time) to service_role;

create or replace function public.onboarding_marcar_dia_da_profissional(
  p_tenant_id uuid, p_nome text, p_data date, p_abre time default null, p_fecha time default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_marcar_dia_da_profissional(p_tenant_id, p_nome, p_data, p_abre, p_fecha); $$;
revoke all on function public.onboarding_marcar_dia_da_profissional(uuid, text, date, time, time) from public, anon, authenticated;
grant execute on function public.onboarding_marcar_dia_da_profissional(uuid, text, date, time, time) to service_role;

-- ---------------------------------------------------------------------------
-- 3. CADASTRAR A PESSOA JA DIZENDO COMO ELA TRABALHA.
--
-- A versao de 3 argumentos sai de cena: ela era justamente a que criava
-- profissional inagendavel sem avisar ninguem.
-- ---------------------------------------------------------------------------

drop function if exists public.onboarding_criar_membro_equipe(uuid, text, text);
drop function if exists app.onboarding_criar_membro_equipe(uuid, text, text);

create or replace function app.onboarding_criar_membro_equipe(
  p_tenant_id       uuid,
  p_nome            text,
  p_tipo            text default 'PROFESSIONAL',
  p_disponibilidade text default 'IGUAL_AO_SALAO'
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
  v_disp     jsonb;
begin
  if v_nome is null or length(v_nome) < 2 or length(v_nome) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'NOME_FORA_DE_FAIXA');
  end if;

  v_tipo := coalesce(v_tipo, 'PROFESSIONAL');
  if v_tipo not in ('PROFESSIONAL', 'ASSISTANT') then
    return jsonb_build_object('ok', false, 'reason', 'TIPO_INVALIDO');
  end if;

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

  -- A disponibilidade vem junto, sempre. Se falhar, a pessoa fica criada e o
  -- motivo volta inteiro: o Eddy pergunta o que falta e chama
  -- `onboarding_definir_disponibilidade` depois, sem recriar ninguem.
  v_disp := app.onboarding_definir_disponibilidade(p_tenant_id, v_nome, p_disponibilidade, null);

  return jsonb_build_object(
    'ok', true, 'pessoaId', v_id, 'pessoa', v_nome,
    'tipo', v_tipo, 'rascunho', v_rascunho,
    'disponibilidade', v_disp
  );
end;
$fn$;

comment on function app.onboarding_criar_membro_equipe(uuid, text, text, text) is
  'Cadastra quem atende E como ela trabalha, na mesma chamada. Criar sem disponibilidade fazia profissional que nunca aparece na agenda.';
revoke all on function app.onboarding_criar_membro_equipe(uuid, text, text, text) from public, anon, authenticated;
grant execute on function app.onboarding_criar_membro_equipe(uuid, text, text, text) to service_role;

create or replace function public.onboarding_criar_membro_equipe(
  p_tenant_id uuid, p_nome text, p_tipo text default 'PROFESSIONAL',
  p_disponibilidade text default 'IGUAL_AO_SALAO'
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_criar_membro_equipe(p_tenant_id, p_nome, p_tipo, p_disponibilidade); $$;
revoke all on function public.onboarding_criar_membro_equipe(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.onboarding_criar_membro_equipe(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. A PENDENCIA QUE FALTAVA NO CATALOGO.
--
-- Nada na lista cobrava disponibilidade, e por isso o salao ficou "pronto"
-- com tres profissionais inagendaveis. Agora cobra, logo depois da equipe.
-- ---------------------------------------------------------------------------

create or replace function app.equipe_sem_disponibilidade(p_tenant_id uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  with rascunho as (
    select d.id from app.configuration_drafts d
     where d.tenant_id = p_tenant_id order by d.revision desc limit 1
  )
  select string_agg(m.name, ', ' order by m.name)
    from app.team_members m, rascunho r
   where m.tenant_id = p_tenant_id
     and m.configuration_draft_id = r.id
     and m.status = 'ACTIVE'
     and not exists (select 1 from app.member_availability a
                      where a.member_id = m.id and a.configuration_draft_id = r.id)
     and not exists (select 1 from app.member_dynamic_shifts s
                      where s.member_id = m.id and s.configuration_draft_id = r.id)
     and m.availability_mode <> 'DYNAMIC';
$function$;

comment on function app.equipe_sem_disponibilidade(uuid) is
  'Quem esta na equipe e nunca pode ser agendado: sem semana e sem datas. DYNAMIC fica de fora -- ali o vazio e a verdade, ela avisa quando vem.';
revoke all on function app.equipe_sem_disponibilidade(uuid) from public, anon, authenticated;
grant execute on function app.equipe_sem_disponibilidade(uuid) to service_role;

-- A lista de pendencias ganha o item. Recriada inteira porque SQL nao edita
-- pedaco de funcao; a diferenca e o item novo e a renumeracao da ordem (de
-- 1..8 para 10..80, para caber um no meio sem empurrar os outros).

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
      select 10 as ordem, jsonb_build_object(
        'campo', 'UNIDADE',
        'perguntaSugerida', 'Como se chama o seu salão, e qual o endereço completo? Rua, número, bairro, cidade e estado.') as item
        from n where n.unidade_nome is null or not n.tem_endereco
      union all
      select 20, jsonb_build_object(
        'campo', 'HORARIOS',
        'perguntaSugerida', 'Que dias e horários o salão atende?')
        from n where n.horarios = 0
      union all
      select 30, jsonb_build_object(
        'campo', 'PROFISSIONAIS',
        'perguntaSugerida', 'Quem atende no salão? Me fala os nomes.')
        from n where n.profissionais = 0
      union all
      -- Sem isto a pessoa existe no cadastro e nunca aparece como opcao de
      -- horario. Em 23/09/2026 o salao de teste ficou assim com as tres.
      select 35, jsonb_build_object(
        'campo', 'DISPONIBILIDADE',
        'perguntaSugerida', 'Falta dizer como ' || n.sem_disponibilidade ||
          ' trabalha: no horário do salão, em dias próprios, ou sem dia fixo? Sem isso ninguém consegue marcar com ela.')
        from n where n.sem_disponibilidade is not null
      union all
      select 40, jsonb_build_object(
        'campo', 'SERVICOS',
        'perguntaSugerida', 'Quais serviços você faz? Pode falar do jeito que você fala com as clientes.')
        from n where n.servicos = 0
      union all
      select 50, jsonb_build_object(
        'campo', 'PRECOS',
        'perguntaSugerida', 'Faltam preços em alguns serviços. Quanto fica cada um?')
        from n where n.servicos_sem_preco > 0
      union all
      select 60, jsonb_build_object(
        'campo', 'REGRAS',
        'perguntaSugerida', 'Tem alguma regra sua que a atendente precisa saber? Do jeito que você diria.')
        from n where n.regras = 0
      union all
      select 70, jsonb_build_object(
        'campo', 'WHATSAPP',
        'perguntaSugerida', 'Falta ligar o WhatsApp do salão. Quer que eu te mande o passo a passo?')
        from n where n.canais = 0
      union all
      select 80, jsonb_build_object(
        'campo', 'PUBLICAR',
        'perguntaSugerida', 'Está tudo cadastrado. Quer que eu publique para a atendente começar a usar?')
        from n where n.canais > 0 and n.servicos > 0 and n.servicos_sem_preco = 0
                and n.sem_disponibilidade is null and not n.publicado
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
-- 5. O MANUAL CITA AS DUAS FERRAMENTAS NOVAS.
--
-- Licao de 18/09, que ja custou uma tarde: o Eddy le "ONDE VOCE PODE ESCREVER"
-- como lista FECHADA. Ferramenta que nao esta ali, para ele, nao existe.
-- ---------------------------------------------------------------------------

update app.agent_prompt_blocks
   set body = replace(
         body,
         '`criar_habilidade` — o que a equipe sabe fazer',
         '`definir_disponibilidade` — como uma pessoa já cadastrada trabalha: no horário do salão, em dias próprios, ou sem dia fixo.

`marcar_dia_da_profissional` — a data em que alguém sem dia fixo vem. Uma chamada por data.

`criar_habilidade` — o que a equipe sabe fazer'),
       updated_at = statement_timestamp()
 where agent = 'DONO' and code = 'EDDY_O_QUE_VOCE_PODE_ESCREVER'
   and body not like '%definir_disponibilidade%';

insert into app.agent_prompt_blocks (agent, code, title, body, position, status)
values ('DONO', 'EDDY_CADASTRAR_NAO_E_AGENDAVEL', 'Cadastrada não quer dizer agendável',
$txt$CADASTRADA NÃO QUER DIZER AGENDÁVEL
Uma pessoa na equipe só aparece como opção de horário para a cliente depois que você disser COMO ela trabalha. Sem isso ela existe no cadastro e a agenda nunca a oferece — e ninguém percebe, porque não dá erro: o salão só nunca tem horário.

São três jeitos, e é assim que o dono fala:

- trabalha no horário do salão — o caso comum, e o padrão.
- tem os dias dela, diferentes dos do salão — aí você precisa dos dias e horários dela.
- vem sem dia fixo — aparece só nas datas que ele avisar, uma por uma.

Quando ele descrever alguém que "vem de vez em quando", "vem quando dá", "a cada quinze dias", "avisa quando vem": isso é sem dia fixo. Não invente uma semana para ela, e não cadastre como se fosse fixa só para não travar — uma profissional com semana inventada faz a agenda oferecer horário que não existe, e quem descobre é a cliente na porta do salão.

Depois de cadastrar alguém sem dia fixo, pergunte quais datas ela já tem. Se ele não souber ainda, tudo bem: diga que é só te avisar quando souber, e siga.$txt$, 37, 'ACTIVE')
on conflict (code) do update
   set agent = excluded.agent, title = excluded.title, body = excluded.body,
       position = excluded.position, status = 'ACTIVE', updated_at = statement_timestamp();
