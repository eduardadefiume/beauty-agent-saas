-- O EDDY PERGUNTA DE COR, E ACEITA FOTO OU AUDIO.
--
-- 24/09/2026. O roteiro do salao novo cobria endereco, horario, equipe,
-- servico, preco e regra -- e parava ai. Para um colorista, a parte que mais
-- decide o orcamento da cliente (ate onde a tinta clareia, quando exige teste
-- de mecha, quanto cobra por nivel, matizacao, pre-pigmentacao) so podia ser
-- respondida na tela. O Eddy nao tinha nem a pergunta nem onde gravar.
--
-- Tres pecas:
--   owner_setup_state   ganha a pendencia CORES, so para salao que tem servico
--                       de cor no rascunho, com as perguntas que faltam
--   eddy_responder_cor  grava a resposta em app.color_policies, a mesma que o
--                       color_plan da atendente ja le
--   EDDY_COR_E_MECHAS   ensina a oferecer foto ou audio antes da primeira
--                       pergunta, e a tirar varias respostas de um audio so

create or replace function app.eddy_responder_cor(
  p_tenant_id uuid,
  p_chave text,
  p_valor numeric,
  p_conversation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_pergunta app.color_policies%rowtype;
  v_restantes integer;
begin
  select * into v_pergunta
    from app.color_policies
   where tenant_id = p_tenant_id and key = upper(trim(coalesce(p_chave, '')));

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'PERGUNTA_NAO_EXISTE');
  end if;

  if p_valor is null or p_valor < 0 then
    return jsonb_build_object('ok', false, 'reason', 'VALOR_INVALIDO');
  end if;

  if (v_pergunta.unit = 'SIM_NAO' and p_valor not in (0, 1))
     or (v_pergunta.unit = 'NIVEIS' and p_valor > 10)
     or (v_pergunta.unit = 'MINUTOS' and p_valor > 600)
     or (v_pergunta.unit = 'REAIS' and p_valor > 100000) then
    return jsonb_build_object('ok', false, 'reason', 'VALOR_FORA_DA_FAIXA', 'unidade', v_pergunta.unit);
  end if;

  update app.color_policies
     set answer_value = p_valor,
         answered_at  = statement_timestamp(),
         answered_by  = 'eddy@whatsapp',
         updated_at   = statement_timestamp()
   where id = v_pergunta.id;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id, correlation_id, result, metadata_minimized
  ) values (
    p_tenant_id, 'SYSTEM', null, 'EDDY_RESPONDEU_COR', 'color_policy', v_pergunta.id,
    encode(extensions.gen_random_bytes(16), 'hex'), 'SUCCESS',
    jsonb_build_object('chave', v_pergunta.key, 'valor', p_valor, 'conversa', p_conversation_id)
  );

  select count(*) into v_restantes
    from app.color_policies
   where tenant_id = p_tenant_id and answered_at is null;

  return jsonb_build_object('ok', true, 'chave', v_pergunta.key, 'valor', p_valor, 'restantes', v_restantes);
end;
$fn$;

revoke all on function app.eddy_responder_cor(uuid, text, numeric, uuid) from public, anon, authenticated;

create or replace function public.eddy_responder_cor(
  p_tenant_id uuid, p_chave text, p_valor numeric, p_conversation_id uuid default null
)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_responder_cor(p_tenant_id, p_chave, p_valor, p_conversation_id); $$;

revoke all on function public.eddy_responder_cor(uuid, text, numeric, uuid) from public, anon, authenticated;
grant execute on function public.eddy_responder_cor(uuid, text, numeric, uuid) to service_role;

create or replace function app.owner_setup_state(p_tenant_id uuid)
 returns jsonb
 language sql
 stable security definer
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
      -- Servico de cor no rascunho. Sem ele a pendencia CORES nao aparece:
      -- barbearia e manicure nao respondem pergunta de descoloracao.
      (select count(*) from app.services s
        where s.tenant_id = p_tenant_id
          and s.configuration_draft_id = (select id from rascunho)
          and s.status = 'ACTIVE'
          and s.name ~* '(colora|\mcor\M|mecha|luzes|balayage|iluminad|loir|ruiv|tonaliz|platin|descolor|matiz|ombr|morena)') as servicos_de_cor,
      (select count(*) from app.color_policies c
        where c.tenant_id = p_tenant_id and c.answered_at is null)             as cores_pendentes,
      (select count(*) from app.tone_family_photos f
        where f.tenant_id = p_tenant_id)                                       as fotos_de_tom,
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
      -- COR E MECHAS. Vem depois do preco porque e o preco do servico de cor
      -- que estas respostas ajustam. As perguntas vao junto para o Eddy tirar
      -- varias respostas de um audio so, sem precisar perguntar uma a uma.
      select 55, jsonb_build_object(
        'campo', 'CORES',
        'perguntaSugerida', 'Agora cor e mechas, que é onde a cliente mais pergunta. Como prefere me ensinar: fotos de trabalhos seus (eu reconheço o tom e guardo para a atendente) ou um áudio explicando como você trabalha com cor?',
        'fotosDeTomGuardadas', n.fotos_de_tom,
        'perguntasDeCor', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'chave', c.key, 'pergunta', c.question, 'ajuda', c.helper,
                   'unidade', c.unit, 'sugestao', c.suggested_value
                 ) order by c.position), '[]'::jsonb)
            from app.color_policies c
           where c.tenant_id = p_tenant_id and c.answered_at is null))
        from n where coalesce(n.escopo_respondido, false)
                 and n.servicos_de_cor > 0 and n.cores_pendentes > 0
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

revoke all on function app.owner_setup_state(uuid) from public, anon, authenticated;

insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
select 'EDDY_COR_E_MECHAS', 'Cor e mechas',
$txt$COR E MECHAS
Quando a pendência for CORES, a primeira mensagem é a pergunta sugerida: ofereça as duas formas, foto ou áudio, e deixe ele escolher. Não comece pela primeira pergunta técnica.

SE ELE MANDAR FOTOS. Siga o que você já sabe das fotos do dono: diga o tom que viu, espere a legenda, arquive com `arquivar_fotos`. Depois de umas fotos arquivadas, puxe as perguntas técnicas.

SE ELE MANDAR ÁUDIO. Um áudio dele costuma responder três ou quatro perguntas de uma vez. Leia a lista perguntasDeCor, tire dali TUDO o que ele respondeu, repita em uma linha ("Entendi: tinta clareia até 2 tons, teste de mecha a partir de 3, matização 30 min e R$ 80. Certo?") e, com o sim dele, chame `responder_cor` uma vez para cada resposta.

O QUE FALTAR, pergunte uma por mensagem, com a sugestão como referência: "A maioria dos salões pede teste de mecha a partir de 3 tons de clareamento. Aí é assim também?" Se ele disser que é igual, grave a sugestão.

Unidades: NIVEIS é número de tons; MINUTOS em minutos; REAIS em reais (0 quando já está incluso); SIM_NAO é 1 para sim e 0 para não.

Se ele disser algo sobre cor que não cabe em nenhuma pergunta ("não faço platinado em cabelo com henna"), é regra: `criar_regra`, assunto PROCEDIMENTO.

Em qualquer etapa, não só na de cor: ele pode responder por áudio. Lembre isso uma vez no começo da conversa, sem repetir a cada pergunta.$txt$,
58, 'ACTIVE', 'DONO'
where not exists (
  select 1 from app.agent_prompt_blocks where agent = 'DONO' and code = 'EDDY_COR_E_MECHAS'
);

update app.agent_prompt_blocks
   set body = replace(
         replace(body,
           'a lista de pendências vem com cinco coisas',
           'a lista de pendências vem com seis coisas'),
         E'5. As regras dele.',
         E'5. Cor e mechas, se o salão faz cor: foto ou áudio, ele escolhe.\n6. As regras dele.'),
       updated_at = statement_timestamp()
 where agent = 'DONO' and code = 'EDDY_O_SALAO_QUE_NASCE_VAZIO' and status = 'ACTIVE';
