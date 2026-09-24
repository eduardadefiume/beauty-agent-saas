-- O ROTEIRO DO EDDY FECHA: REDES SOCIAIS, MENSAGEM DE CONFIRMACAO E LEMBRETE.
--
-- 24/09/2026. Tres coisas que o dono decide e que ninguem perguntava:
--
--   REDES_SOCIAIS            o Instagram do salao. A atendente nao tinha como
--                            mandar para a cliente que pede "tem insta?".
--   MENSAGEM_DE_CONFIRMACAO  o texto (e/ou a arte) que fecha o agendamento.
--                            final_message_template existia no rascunho e ia
--                            para o snapshot publicado -- e ninguem enviava.
--   LEMBRETE                 se lembra na vespera, a que horas, e o texto que
--                            ele gostaria. O texto que sai hoje e o do modelo
--                            aprovado pela Meta; texto proprio vira pedido
--                            registrado, porque exige modelo novo aprovado.
--
-- E a atendente ganha o que faltava para responder "onde fica?": o endereco
-- da unidade entra no contexto dela, junto com as redes.

alter table app.units
  add column if not exists redes_sociais jsonb not null default '{}'::jsonb,
  add column if not exists redes_respondidas_em timestamptz;

alter table app.agent_scope
  add column if not exists confirmacao_definida_em timestamptz,
  add column if not exists confirmacao_foto_caminho text,
  add column if not exists lembrete_definido_em timestamptz,
  add column if not exists lembrete_texto_desejado text;

alter table app.midias_do_dono drop constraint if exists midias_do_dono_destino_check;
alter table app.midias_do_dono add constraint midias_do_dono_destino_check
  check (destino in ('FAMILIA_DE_TOM', 'OPCAO_DA_REGUA', 'REGRA', 'CONHECIMENTO', 'PORTFOLIO', 'DESCARTADA', 'CONFIRMACAO'));

-- REDES. "Nao tem" tambem e resposta: marca respondido com o objeto vazio,
-- para a pergunta nao voltar.
create or replace function app.eddy_definir_redes(
  p_tenant_id uuid,
  p_instagram text default null,
  p_facebook text default null,
  p_tiktok text default null,
  p_site text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_redes jsonb;
  v_instagram text := nullif(regexp_replace(trim(coalesce(p_instagram, '')),
                        '^(https?://)?(www\.)?instagram\.com/|^@|/$', '', 'gi'), '');
begin
  v_redes := jsonb_strip_nulls(jsonb_build_object(
    'instagram', case when v_instagram is not null then '@' || v_instagram end,
    'instagramLink', case when v_instagram is not null then 'https://instagram.com/' || v_instagram end,
    'facebook', nullif(trim(coalesce(p_facebook, '')), ''),
    'tiktok', nullif(trim(coalesce(p_tiktok, '')), ''),
    'site', nullif(trim(coalesce(p_site, '')), '')));

  update app.units u
     set redes_sociais = v_redes,
         redes_respondidas_em = statement_timestamp(),
         updated_at = statement_timestamp()
   where u.id = (select u2.id from app.units u2 where u2.tenant_id = p_tenant_id
                  order by u2.created_at limit 1);

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_SEM_UNIDADE');
  end if;
  return jsonb_build_object('ok', true, 'redes', v_redes);
end;
$fn$;

revoke all on function app.eddy_definir_redes(uuid, text, text, text, text) from public, anon, authenticated;

create or replace function public.eddy_definir_redes(
  p_tenant_id uuid, p_instagram text default null, p_facebook text default null,
  p_tiktok text default null, p_site text default null
)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_definir_redes(p_tenant_id, p_instagram, p_facebook, p_tiktok, p_site); $$;

revoke all on function public.eddy_definir_redes(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.eddy_definir_redes(uuid, text, text, text, text) to service_role;

-- CONFIRMACAO. O texto vai para o rascunho (sai para a cliente depois de
-- publicar, como preco); a arte vale na hora, e e uma foto que o dono ja
-- mandou nesta conversa. O caminho guardado e o da pasta do salao no balde
-- `conhecimento`; o envio procura la quando nao acha em `anexos`.
create or replace function app.eddy_definir_confirmacao(
  p_tenant_id uuid,
  p_texto text default null,
  p_foto uuid default null,
  p_conversation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_texto text := nullif(trim(coalesce(p_texto, '')), '');
  v_rascunho uuid;
  v_caminho text;
begin
  if v_texto is null and p_foto is null then
    return jsonb_build_object('ok', false, 'reason', 'NEM_TEXTO_NEM_FOTO');
  end if;
  if v_texto is not null and length(v_texto) > 1000 then
    return jsonb_build_object('ok', false, 'reason', 'TEXTO_LONGO_DEMAIS');
  end if;

  if p_foto is not null then
    select m.storage_path into v_caminho
      from app.midias_do_dono m
     where m.id = p_foto and m.tenant_id = p_tenant_id;
    if v_caminho is null then
      return jsonb_build_object('ok', false, 'reason', 'FOTO_NAO_ENCONTRADA_OU_SEM_ARQUIVO');
    end if;
    update app.midias_do_dono
       set destino = 'CONFIRMACAO', destinado_em = statement_timestamp()
     where id = p_foto;
  end if;

  if v_texto is not null then
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
    update app.configuration_drafts
       set final_message_template = v_texto, updated_at = statement_timestamp()
     where id = v_rascunho;
  end if;

  update app.agent_scope
     set confirmacao_definida_em = statement_timestamp(),
         confirmacao_foto_caminho = coalesce(v_caminho, confirmacao_foto_caminho),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'PERGUNTE_ANTES_O_QUE_O_AGENTE_FAZ');
  end if;

  return jsonb_build_object('ok', true, 'texto', v_texto, 'textoVaiParaORascunho', v_texto is not null,
                            'arte', v_caminho is not null);
end;
$fn$;

revoke all on function app.eddy_definir_confirmacao(uuid, text, uuid, uuid) from public, anon, authenticated;

create or replace function public.eddy_definir_confirmacao(
  p_tenant_id uuid, p_texto text default null, p_foto uuid default null, p_conversation_id uuid default null
)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_definir_confirmacao(p_tenant_id, p_texto, p_foto, p_conversation_id); $$;

revoke all on function public.eddy_definir_confirmacao(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.eddy_definir_confirmacao(uuid, text, uuid, uuid) to service_role;

-- LEMBRETE. Liga e desliga de verdade (agendar_lembretes_da_vespera le estas
-- colunas). O texto proprio fica registrado como pedido: sair com ele exige
-- um modelo novo aprovado pela Meta, e isso e trabalho da Eduarda.
create or replace function app.eddy_definir_lembrete(
  p_tenant_id uuid,
  p_quer boolean,
  p_hora integer default null,
  p_texto_desejado text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_texto text := nullif(trim(coalesce(p_texto_desejado, '')), '');
begin
  if p_quer is null then
    return jsonb_build_object('ok', false, 'reason', 'DIGA_SE_ELE_QUER');
  end if;
  if p_hora is not null and p_hora not between 8 and 21 then
    return jsonb_build_object('ok', false, 'reason', 'HORA_FORA_DE_8_A_21');
  end if;

  update app.agent_scope
     set lembra_da_vespera = p_quer,
         lembrete_hora_local = coalesce(p_hora, lembrete_hora_local),
         lembrete_texto_desejado = v_texto,
         lembrete_definido_em = statement_timestamp(),
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'PERGUNTE_ANTES_O_QUE_O_AGENTE_FAZ');
  end if;

  if v_texto is not null then
    insert into app.audit_logs (
      tenant_id, actor_type, actor_id, action, entity_type, entity_id, correlation_id, result, metadata_minimized
    ) values (
      p_tenant_id, 'SYSTEM', null, 'LEMBRETE_TEXTO_PROPRIO_PEDIDO', 'agent_scope', null,
      encode(extensions.gen_random_bytes(16), 'hex'), 'SUCCESS', jsonb_build_object('texto', v_texto)
    );
  end if;

  return jsonb_build_object(
    'ok', true, 'lembra', p_quer,
    'hora', (select lembrete_hora_local from app.agent_scope where tenant_id = p_tenant_id),
    'textoProprioPedido', v_texto is not null);
end;
$fn$;

revoke all on function app.eddy_definir_lembrete(uuid, boolean, integer, text) from public, anon, authenticated;

create or replace function public.eddy_definir_lembrete(
  p_tenant_id uuid, p_quer boolean, p_hora integer default null, p_texto_desejado text default null
)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_definir_lembrete(p_tenant_id, p_quer, p_hora, p_texto_desejado); $$;

revoke all on function public.eddy_definir_lembrete(uuid, boolean, integer, text) from public, anon, authenticated;
grant execute on function public.eddy_definir_lembrete(uuid, boolean, integer, text) to service_role;

-- A FINALIZACAO SAI DEPOIS DO "MARCADO". Chamada pela atendente quando a
-- agenda confirma, depois de enfileirar a resposta dela. Deterministica: o
-- texto e o do dono, com as lacunas preenchidas aqui, e nao reescrito pelo
-- modelo.
create or replace function app.enviar_finalizacao_do_agendamento(
  p_conversation_id uuid,
  p_appointment_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_ag record;
  v_texto text;
  v_foto text;
  v_local timestamp;
  v_nome text;
  v_endereco text;
  v_r1 jsonb;
  v_r2 jsonb;
begin
  select a.*, u.timezone, t.display_name as salao, u.address_json
    into v_ag
    from app.appointments a
    join app.units u on u.id = a.unit_id
    join app.tenants t on t.id = a.tenant_id
   where a.id = p_appointment_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'AGENDAMENTO_NAO_EXISTE');
  end if;

  select cv.snapshot->>'finalMessageTemplate' into v_texto
    from app.configuration_versions cv
   where cv.id = v_ag.configuration_version_id;
  select sc.confirmacao_foto_caminho into v_foto
    from app.agent_scope sc where sc.tenant_id = v_ag.tenant_id;

  v_texto := nullif(trim(coalesce(v_texto, '')), '');
  if v_texto is null and v_foto is null then
    return jsonb_build_object('ok', true, 'enviado', false, 'reason', 'SALAO_SEM_FINALIZACAO');
  end if;

  v_local := v_ag.starts_at at time zone v_ag.timezone;
  v_nome := nullif(split_part(trim(coalesce(v_ag.customer_label, '')), ' ', 1), '');
  v_endereco := nullif(v_ag.address_json->>'texto', '');

  if v_texto is not null then
    v_texto := replace(v_texto, '{nome}', coalesce(v_nome, ''));
    v_texto := replace(v_texto, '{data}', to_char(v_local, 'DD/MM'));
    v_texto := replace(v_texto, '{hora}', to_char(v_local, 'HH24:MI'));
    v_texto := replace(v_texto, '{servico}', coalesce((select s.name from app.services s where s.id = v_ag.service_id), ''));
    v_texto := replace(v_texto, '{salao}', v_ag.salao);
    v_texto := replace(v_texto, '{endereco}', coalesce(v_endereco, ''));
    v_texto := regexp_replace(v_texto, '\s+([,.!?])', '\1', 'g');
    v_texto := regexp_replace(v_texto, '[ \t]{2,}', ' ', 'g');
  end if;

  if v_foto is not null then
    v_r1 := app.enqueue_outbound_message(
      v_ag.tenant_id, p_conversation_id, coalesce(v_texto, ''), 'AGENT',
      'finalizacao:' || p_appointment_id::text || ':arte', null,
      v_foto, case when v_foto ~* '\.png$' then 'image/png' else 'image/jpeg' end, null);
  elsif v_texto is not null then
    v_r1 := app.enqueue_outbound_message(
      v_ag.tenant_id, p_conversation_id, v_texto, 'AGENT',
      'finalizacao:' || p_appointment_id::text, null, null, null, null);
  end if;

  return jsonb_build_object('ok', true, 'enviado', true, 'texto', v_texto, 'arte', v_foto is not null,
                            'fila', v_r1);
end;
$fn$;

revoke all on function app.enviar_finalizacao_do_agendamento(uuid, uuid) from public, anon, authenticated;

create or replace function public.enviar_finalizacao_do_agendamento(p_conversation_id uuid, p_appointment_id uuid)
returns jsonb language sql security definer set search_path to ''
as $$ select app.enviar_finalizacao_do_agendamento(p_conversation_id, p_appointment_id); $$;

revoke all on function public.enviar_finalizacao_do_agendamento(uuid, uuid) from public, anon, authenticated;
grant execute on function public.enviar_finalizacao_do_agendamento(uuid, uuid) to service_role;

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
      (select redes_respondidas_em is not null from unidade)                  as redes_respondidas,
      (select confirmacao_definida_em is not null from escopo)                as confirmacao_definida,
      (select lembrete_definido_em is not null from escopo)                   as lembrete_definido,
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
      -- Redes sociais logo depois do endereco: e o que a cliente pede junto
      -- ("tem Instagram pra eu ver os trabalhos?"), e o Eddy ja esta falando
      -- do salao como lugar.
      select 12, jsonb_build_object(
        'campo', 'REDES_SOCIAIS',
        'perguntaSugerida', 'Qual o Instagram do salão? Se tiver Facebook, TikTok ou site, pode mandar também. A atendente passa para quem quiser ver os trabalhos.')
        from n where coalesce(n.escopo_respondido, false)
                 and not coalesce(n.redes_respondidas, false)
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
      -- As duas so existem para quem marca: sem agendamento nao ha o que
      -- finalizar nem de que lembrar.
      select 62, jsonb_build_object(
        'campo', 'MENSAGEM_DE_CONFIRMACAO',
        'perguntaSugerida', 'Quando eu marcar uma cliente, o que ela recebe para fechar? Pode ser um texto seu (com nome, dia, hora, serviço e endereço, eu preencho), uma imagem sua (arte com endereço e recados) ou os dois.')
        from n where coalesce(n.escopo_respondido, false) and n.marca_horario
                 and not coalesce(n.confirmacao_definida, false)
      union all
      select 64, jsonb_build_object(
        'campo', 'LEMBRETE',
        'perguntaSugerida', 'Quer que eu lembre a cliente na véspera do horário? A que horas? A mensagem é assim: "Oi Ana! Lembrando do seu horário amanhã, 25/09, às 14:00, no ' || coalesce((select t.display_name from app.tenants t where t.id = p_tenant_id), 'salão') || '."')
        from n where coalesce(n.escopo_respondido, false) and n.marca_horario
                 and not coalesce(n.lembrete_definido, false)
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

-- O CONTEXTO DA ATENDENTE GANHA ENDERECO E REDES. Emenda por substituicao
-- sobre a definicao viva, com trava: se a ancora sumiu, a migracao para.
do $mig$
declare
  v_def text := pg_get_functiondef('app.build_agent_context(uuid, integer)'::regprocedure);
  c_ancora constant text := E'    ''policies'', app.agent_policies_for_agent(v_c.tenant_id),';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de build_agent_context sumiu';
  end if;
  if position('''address''' in v_def) > 0 then
    raise exception 'build_agent_context ja tem address';
  end if;
  v_def := replace(v_def, c_ancora,
    E'    ''address'', (select nullif(u.address_json->>''texto'', '''') from app.units u\n'
    || E'                   where u.tenant_id = v_c.tenant_id order by u.created_at limit 1),\n'
    || E'    ''socialMedia'', (select nullif(u.redes_sociais, ''{}''::jsonb) from app.units u\n'
    || E'                   where u.tenant_id = v_c.tenant_id order by u.created_at limit 1),\n'
    || c_ancora);
  execute v_def;
end
$mig$;

insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
select 'EDDY_FECHAMENTO_E_LEMBRETE', 'Redes, confirmação e lembrete',
$txt$REDES, CONFIRMAÇÃO E LEMBRETE
REDES_SOCIAIS. Grave com `definir_redes`. Se ele disser que não tem, chame mesmo assim, sem nada: "não tem" também é resposta e a pergunta não volta.

MENSAGEM_DE_CONFIRMACAO. É o que a cliente recebe logo depois de marcar, e sai exatamente como ele escrever. Ofereça as lacunas que você preenche: {nome}, {data}, {hora}, {servico}, {salao}, {endereco}. Se ele mandar o texto dele, troque as partes que mudam pelas lacunas, mostre como ficou e, com o sim dele, chame `definir_confirmacao`. Se ele mandar uma imagem (arte com endereço, regras do salão), é a foto sem lugar dele: `definir_confirmacao` com o id da foto. Pode ter os dois. Se ele não quiser nada, a atendente só confirma o horário e pronto; não insista.

LEMBRETE. Mostre o texto como ele sai hoje e pergunte se quer e a que horas (entre 8 e 21). Grave com `definir_lembrete`. Se ele quiser outro texto, grave o texto dele em textoDesejado e diga a verdade: esse texto precisa ser aprovado pelo WhatsApp, a Eduarda cuida disso, e até lá sai o padrão.$txt$,
63, 'ACTIVE', 'DONO'
where not exists (
  select 1 from app.agent_prompt_blocks where agent = 'DONO' and code = 'EDDY_FECHAMENTO_E_LEMBRETE'
);
