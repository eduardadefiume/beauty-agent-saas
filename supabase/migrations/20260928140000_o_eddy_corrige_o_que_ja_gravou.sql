-- O EDDY CORRIGE O QUE JA GRAVOU.
--
-- 28/09/2026, bateria de casos reais (dono-robo "William", salao Robo 2, DEV).
-- Quatro coisas que o dono pediu e o Eddy nao conseguia fazer -- e em duas
-- delas ele DISSE que tinha feito:
--
--   1. "A escova subiu, agora e 80." Depois de publicado, o Eddy pediu
--      confirmacao, recebeu "isso, 80", e pediu confirmacao de novo, em laco.
--      Causa: `definir_preco`, `criar_variacao` e `definir_pausa` exigem o id
--      do servico, e o id so aparecia na lista de PENDENCIAS. Servico pronto
--      nao e pendencia; o cadastro que ele le vem sem id. Sem id, nao grava.
--      Foi a mesma causa do "com muito volume e 450" que ele disse ter anotado
--      e nao anotou.
--   2. "A primeira foto nao e iluminado, e castanho claro tom 6, corrige la."
--      Ele respondeu "Corrigido" e a foto continuou em Iluminado: arquivar so
--      aceita foto SEM destino, e nao havia como mudar uma ja arquivada.
--   3. O tom que o dono diz ("tom 1", "tom 6") nao ficava em lugar nenhum: a
--      foto guardava so o tom que a IA leu.
--   4. "Preto natural nao e castanho, cria uma familia preto." O catalogo do
--      produto comecava no tom 3; tons 1 e 2 nao tinham familia.
--
-- E um detalhe que envelhece mal: o exemplo do lembrete dizia "amanha,
-- 25/09" para sempre.

-- 1. Achar o servico pelo nome (ou pelo id), do jeito que o dono chama.
create or replace function app.eddy_resolver_servico(p_tenant_id uuid, p_texto text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_txt   text := lower(trim(coalesce(p_texto, '')));
  v_id    uuid;
  v_nome  text;
  v_quant integer;
begin
  if v_txt = '' then
    return jsonb_build_object('ok', false, 'reason', 'VAZIO');
  end if;

  -- Veio o id: confere que e deste salao.
  if v_txt ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select s.id, s.name into v_id, v_nome
      from app.services s
     where s.id = v_txt::uuid and s.tenant_id = p_tenant_id and s.status = 'ACTIVE';
    if v_id is not null then
      return jsonb_build_object('ok', true, 'id', v_id, 'nome', v_nome);
    end if;
  end if;

  -- Nome exato (sem diferenca de maiuscula/acento).
  -- Cada rascunho repete os servicos: conta NOMES, nao linhas. Qualquer id
  -- do nome serve -- `servico_no_rascunho` leva ao rascunho atual.
  select count(distinct lower(s.name)), min(s.id::text)::uuid, min(s.name) into v_quant, v_id, v_nome
    from app.services s
   where s.tenant_id = p_tenant_id and s.status = 'ACTIVE'
     and lower(extensions.unaccent(s.name)) = lower(extensions.unaccent(v_txt));
  if v_quant = 1 then
    return jsonb_build_object('ok', true, 'id', v_id, 'nome', v_nome);
  end if;

  -- Comeco do nome ("escova" -> "Escova", mas nao "Corte com escova").
  select count(distinct lower(s.name)), min(s.id::text)::uuid, min(s.name) into v_quant, v_id, v_nome
    from app.services s
   where s.tenant_id = p_tenant_id and s.status = 'ACTIVE'
     and lower(extensions.unaccent(s.name)) like lower(extensions.unaccent(v_txt)) || '%';
  if v_quant = 1 then
    return jsonb_build_object('ok', true, 'id', v_id, 'nome', v_nome);
  end if;

  return jsonb_build_object(
    'ok', false,
    'reason', case when v_quant > 1 then 'AMBIGUO' else 'NAO_EXISTE' end,
    'servicos', (select jsonb_agg(distinct s.name) from app.services s
                  where s.tenant_id = p_tenant_id and s.status = 'ACTIVE'));
end;
$fn$;

create or replace function public.eddy_resolver_servico(p_tenant_id uuid, p_texto text)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.eddy_resolver_servico(p_tenant_id, p_texto); $$;

-- 1b. Mudar a DURACAO de um servico que ja existe ("a progressiva agora
-- demora 4h"). O total e o que o dono diz; a pausa fica como esta e o
-- atendimento vira o resto.
create or replace function app.eddy_definir_duracao(p_tenant_id uuid, p_servico text, p_minutos integer)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_rascunho uuid;
  v_servico  uuid;
  v_nome     text;
  v_pausa    integer;
  v_ativas   integer;
  v_nova     integer;
  v_antes    integer;
begin
  if p_minutos is null or p_minutos < 5 or p_minutos > 720 then
    return jsonb_build_object('ok', false, 'reason', 'DURACAO_FORA_DE_FAIXA');
  end if;
  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'SEM_RASCUNHO_DE_ORIGEM');
  end;

  select s.id, s.name into v_servico, v_nome
    from app.services s
   where s.tenant_id = p_tenant_id and s.configuration_draft_id = v_rascunho and s.status = 'ACTIVE'
     and lower(extensions.unaccent(s.name)) = lower(extensions.unaccent(trim(coalesce(p_servico, ''))))
   limit 1;
  if v_servico is null then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_NAO_EXISTE', 'servico', p_servico);
  end if;

  select coalesce(sum(t.duration_minutes) filter (where t.kind = 'PASSIVE'), 0),
         count(*) filter (where t.kind = 'ACTIVE'),
         coalesce(sum(t.duration_minutes), 0)
    into v_pausa, v_ativas, v_antes
    from app.service_steps t
   where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho and t.service_id = v_servico;

  if v_ativas <> 1 then
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_TEM_ETAPAS_DEMAIS',
      'comoResolver', 'Este servico tem mais de uma etapa de atendimento; ajuste na tela do configurador.');
  end if;
  v_nova := p_minutos - v_pausa;
  if v_nova < 5 then
    return jsonb_build_object('ok', false, 'reason', 'DURACAO_MENOR_QUE_A_PAUSA', 'pausaMinutos', v_pausa);
  end if;

  update app.service_steps
     set duration_minutes = v_nova, minimum_duration_minutes = v_nova, maximum_duration_minutes = v_nova,
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id and configuration_draft_id = v_rascunho
     and service_id = v_servico and kind = 'ACTIVE';

  return jsonb_build_object('ok', true, 'servico', v_nome, 'totalAntes', v_antes,
                            'totalMinutos', p_minutos, 'pausaMinutos', v_pausa, 'atendimentoMinutos', v_nova);
end;
$fn$;

create or replace function public.eddy_definir_duracao(p_tenant_id uuid, p_servico text, p_minutos integer)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_definir_duracao(p_tenant_id, p_servico, p_minutos); $$;

-- 1c. Mudar os MINUTOS de uma pausa que ja existe. Antes era recusado
-- (SERVICO_JA_TEM_PAUSA). Dentro do total: o total fica e o atendimento
-- absorve a diferenca. Fora do total: o total muda junto.
do $patch$
declare
  v_def   text := pg_get_functiondef('app.onboarding_definir_pausa(uuid,text,integer,boolean,boolean)'::regprocedure);
  v_velho text := $v$    return jsonb_build_object('ok', false, 'reason', 'SERVICO_JA_TEM_PAUSA', 'servico', v_nome,
                              'pausaAtual', v_pausa.duration_minutes);$v$;
  v_novo  text := $v$    select count(*) into v_quantas
      from app.service_steps t
     where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho
       and t.service_id = v_servico and t.kind = 'ACTIVE';
    if v_quantas <> 1 then
      return jsonb_build_object('ok', false, 'reason', 'SERVICO_TEM_ETAPAS_DEMAIS', 'etapasAtivas', v_quantas);
    end if;
    select t.id, t.duration_minutes, t.position into v_ativa
      from app.service_steps t
     where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho
       and t.service_id = v_servico and t.kind = 'ACTIVE';
    if p_dentro_do_total then
      v_nova_ativa := v_ativa.duration_minutes + v_pausa.duration_minutes - p_minutos;
      if v_nova_ativa < 5 then
        return jsonb_build_object('ok', false, 'reason', 'PAUSA_MAIOR_QUE_O_SERVICO',
          'totalAtual', v_ativa.duration_minutes + v_pausa.duration_minutes, 'pausaPedida', p_minutos);
      end if;
      update app.service_steps
         set duration_minutes = v_nova_ativa, minimum_duration_minutes = v_nova_ativa,
             maximum_duration_minutes = v_nova_ativa, updated_at = statement_timestamp()
       where id = v_ativa.id;
    else
      v_nova_ativa := v_ativa.duration_minutes;
    end if;
    update app.service_steps
       set duration_minutes = p_minutos, minimum_duration_minutes = p_minutos,
           maximum_duration_minutes = p_minutos, releases_member = v_libera,
           name = case when v_libera then 'Pausa' else 'Pausa acompanhada' end,
           updated_at = statement_timestamp()
     where id = v_pausa.id;
    return jsonb_build_object('ok', true, 'servico', v_nome, 'pausaMinutos', p_minutos,
      'pausaAntes', v_pausa.duration_minutes, 'atendimentoMinutos', v_nova_ativa,
      'totalMinutos', v_nova_ativa + p_minutos, 'liberaProfissional', v_libera, 'corrigida', true);$v$;
begin
  if position(v_velho in v_def) = 0 then
    raise exception 'onboarding_definir_pausa: trecho SERVICO_JA_TEM_PAUSA nao encontrado';
  end if;
  execute replace(v_def, v_velho, v_novo);
end
$patch$;

-- 2 e 3. Mudar uma foto ja arquivada de lugar e/ou gravar o tom que o dono
-- disse. A foto e a da conversa (midias_do_dono); o arquivo nao muda, so o
-- lugar onde a atendente o encontra.
create or replace function app.eddy_corrigir_foto(
  p_tenant_id       uuid,
  p_conversation_id uuid,
  p_foto            uuid,
  p_familia         text,
  p_tom             smallint default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_foto    app.midias_do_dono;
  v_familia uuid;
  v_nome    text;
begin
  select * into v_foto from app.midias_do_dono f
   where f.id = p_foto and f.tenant_id = p_tenant_id and f.conversation_id = p_conversation_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'FOTO_NAO_ENCONTRADA');
  end if;
  if v_foto.storage_path is null then
    return jsonb_build_object('ok', false, 'reason', 'FOTO_SEM_ARQUIVO');
  end if;
  if p_tom is not null and not exists (select 1 from app.tone_levels l where l.level = p_tom) then
    return jsonb_build_object('ok', false, 'reason', 'TOM_INVALIDO');
  end if;

  select tf.id, tf.name into v_familia, v_nome
    from app.tone_families tf
   where tf.tenant_id = p_tenant_id and tf.status = 'ACTIVE'
     and lower(extensions.unaccent(tf.name)) = lower(extensions.unaccent(trim(coalesce(p_familia, ''))));
  if v_familia is null then
    return jsonb_build_object('ok', false, 'reason', 'FAMILIA_NAO_EXISTE',
      'familias', (select jsonb_agg(tf.name order by tf.position) from app.tone_families tf
                    where tf.tenant_id = p_tenant_id and tf.status = 'ACTIVE'));
  end if;

  -- Sai de onde estiver (familia de tom ou opcao da regua) e entra na certa.
  delete from app.tone_family_photos p
   where p.tenant_id = p_tenant_id and p.storage_path = v_foto.storage_path;
  delete from app.knowledge_reference_photos p
   where p.tenant_id = p_tenant_id and p.storage_path = v_foto.storage_path;

  insert into app.tone_family_photos (tenant_id, family_id, storage_path, caption, position,
                                      estimated_level, level_source)
  values (p_tenant_id, v_familia, v_foto.storage_path, left(v_foto.leitura, 500),
          (select coalesce(max(p.position), 0) + 1 from app.tone_family_photos p where p.family_id = v_familia),
          p_tom, case when p_tom is null then 'LIDO_NA_FOTO' else 'PESSOA' end);

  update app.midias_do_dono
     set destino = 'FAMILIA_DE_TOM', destino_id = v_familia, destinado_em = statement_timestamp()
   where id = v_foto.id;

  return jsonb_build_object('ok', true, 'familia', v_nome, 'tom', p_tom);
end;
$fn$;

create or replace function public.eddy_corrigir_foto(
  p_tenant_id uuid, p_conversation_id uuid, p_foto uuid, p_familia text, p_tom smallint default null)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_corrigir_foto(p_tenant_id, p_conversation_id, p_foto, p_familia, p_tom); $$;

-- O Eddy passa a VER as fotos que ja arquivou nesta conversa (com o id que a
-- correcao usa) e a faixa de tom de cada familia.
create or replace function app.eddy_regua_e_fotos(p_tenant_id uuid, p_conversation_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $fn$
  select jsonb_build_object(
    'fotosSemDestino', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id,
               'recebidaEm', to_char(f.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'assunto', f.assunto,
               'certeza', f.certeza,
               'leitura', left(f.leitura, 300),
               'arquivoGuardado', f.storage_path is not null)
             order by f.created_at)
        from app.midias_do_dono f
       where f.tenant_id = p_tenant_id
         and f.conversation_id = p_conversation_id
         and f.destino is null
         and f.created_at > statement_timestamp() - interval '7 days'
    ), '[]'::jsonb),
    'fotosJaArquivadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id,
               'recebidaEm', to_char(f.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'onde', coalesce(
                 (select 'Família ' || tf.name || coalesce(' (tom ' || p.estimated_level ||
                         case p.level_source when 'PESSOA' then ', dito pelo dono' else ', lido na foto' end || ')', '')
                    from app.tone_family_photos p join app.tone_families tf on tf.id = p.family_id
                   where p.tenant_id = p_tenant_id and p.storage_path = f.storage_path limit 1),
                 (select 'Régua: ' || o.label from app.knowledge_reference_photos p
                    join app.knowledge_options o on o.id = p.option_id
                   where p.tenant_id = p_tenant_id and p.storage_path = f.storage_path limit 1),
                 f.destino),
               'leitura', left(f.leitura, 160))
             order by f.created_at)
        from app.midias_do_dono f
       where f.tenant_id = p_tenant_id
         and f.conversation_id = p_conversation_id
         and f.destino is not null
         and f.created_at > statement_timestamp() - interval '7 days'
    ), '[]'::jsonb),
    'familiasDeTom', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nome', tf.name,
               'tons', coalesce(tf.min_level::text || ' a ' || tf.max_level::text, '?'),
               'fotos', (select count(*) from app.tone_family_photos p where p.family_id = tf.id))
             order by tf.position, tf.name)
        from app.tone_families tf
       where tf.tenant_id = p_tenant_id and tf.status = 'ACTIVE'
    ), '[]'::jsonb),
    'regua', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dimensao', d.name,
               'opcoes', coalesce((
                 select jsonb_agg(o.label order by o.position, o.label)
                   from app.knowledge_options o
                  where o.dimension_id = d.id and o.status = 'ACTIVE'
               ), '[]'::jsonb))
             order by d.position, d.name)
        from app.knowledge_dimensions d
       where d.tenant_id = p_tenant_id and d.status = 'ACTIVE'
    ), '[]'::jsonb)
  );
$fn$;

-- 4. Familia Preto (tons 1 e 2) no catalogo do produto e em todo salao que
-- ja tem as familias do produto.
insert into app.product_tone_families (code, name, position, min_level, max_level, description, needs_warm_base)
select 'PRETO', 'Preto', 0, 1, 2, 'Preto natural e castanho muito escuro.', false
where not exists (select 1 from app.product_tone_families where code = 'PRETO');

insert into app.tone_families (tenant_id, name, description, min_level, max_level, needs_warm_base,
                               position, status, origin, product_code)
select t.tenant_id, 'Preto', 'Preto natural e castanho muito escuro.', 1, 2, false, 0, 'ACTIVE', 'PRODUTO', 'PRETO'
  from (select distinct tf.tenant_id from app.tone_families tf where tf.origin in ('PRODUTO', 'PRODUTO_AJUSTADO')) t
 where not exists (select 1 from app.tone_families x where x.tenant_id = t.tenant_id and lower(x.name) = 'preto');

-- 5. O exemplo do lembrete com a data de amanha de verdade.
do $patch$
declare
  v_def   text := pg_get_functiondef('app.owner_setup_state(uuid)'::regprocedure);
  v_velho text := $v$Lembrando do seu horário amanhã, 25/09, às 14:00, no $v$;
  v_novo  text := $v$Lembrando do seu horário amanhã, ' || to_char((statement_timestamp() at time zone 'America/Sao_Paulo')::date + 1, 'DD/MM') || ', às 14:00, no $v$;
begin
  if position(v_velho in v_def) = 0 then
    raise exception 'owner_setup_state: exemplo do lembrete nao encontrado';
  end if;
  execute replace(v_def, v_velho, v_novo);
end
$patch$;

-- 6. Os valores que estao gravados, para a trava do "anotei" conferir cada
-- R$ que o Eddy diz ter anotado: preco de servico, de variacao, acrescimo de
-- familia de tom e numero escrito numa regra ("parcelo acima de 300").
create or replace function app.eddy_valores_gravados(p_tenant_id uuid)
returns numeric[]
language sql
stable
security definer
set search_path to ''
as $fn$
  select coalesce(array_agg(distinct v), '{}')
    from (
      select s.base_price_minor / 100.0 v from app.services s
       where s.tenant_id = p_tenant_id and s.base_price_minor is not null
      union all
      select sv.price_minor / 100.0 from app.service_variations sv
       where sv.tenant_id = p_tenant_id and sv.price_minor is not null
      union all
      select tf.extra_price_minor / 100.0 from app.tone_families tf
       where tf.tenant_id = p_tenant_id and tf.extra_price_minor is not null
      union all
      select replace(m[1], ',', '.')::numeric
        from app.agent_policies ap, regexp_matches(ap.body, '(\d{1,5}(?:[.,]\d{1,2})?)', 'g') m
       where ap.tenant_id = p_tenant_id
    ) x;
$fn$;

create or replace function public.eddy_valores_gravados(p_tenant_id uuid)
returns numeric[] language sql stable security definer set search_path to ''
as $$ select app.eddy_valores_gravados(p_tenant_id); $$;

revoke all on function app.eddy_resolver_servico(uuid, text) from public, anon, authenticated;
revoke all on function app.eddy_valores_gravados(uuid) from public, anon, authenticated;
revoke all on function public.eddy_valores_gravados(uuid) from public, anon, authenticated;
revoke all on function public.eddy_resolver_servico(uuid, text) from public, anon, authenticated;
revoke all on function app.eddy_corrigir_foto(uuid, uuid, uuid, text, smallint) from public, anon, authenticated;
revoke all on function app.eddy_definir_duracao(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.eddy_definir_duracao(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.eddy_corrigir_foto(uuid, uuid, uuid, text, smallint) from public, anon, authenticated;
revoke all on function app.eddy_regua_e_fotos(uuid, uuid) from public, anon, authenticated;
grant execute on function public.eddy_resolver_servico(uuid, text) to service_role;
grant execute on function public.eddy_corrigir_foto(uuid, uuid, uuid, text, smallint) to service_role;
grant execute on function public.eddy_definir_duracao(uuid, text, integer) to service_role;
grant execute on function public.eddy_valores_gravados(uuid) to service_role;
