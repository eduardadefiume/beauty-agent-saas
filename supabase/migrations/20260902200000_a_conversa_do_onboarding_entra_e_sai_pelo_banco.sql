-- ETAPA 5, parte 4: as duas portas que a função de borda usa.
--
-- A borda não conhece salão nem sessão: ela só sabe conversar com o modelo.
-- Quem confere crachá é o banco, aqui, como em todo o resto do configurador --
-- `require_site_tenant` mora de um lado só, e é por isso que ele não diverge.
--
-- `site_onboarding_turn` registra o que o dono falou e devolve a pauta.
-- `site_onboarding_record` recebe o que o modelo entendeu e aplica ou parqueia.

create or replace function public.site_onboarding_turn(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_session_id      uuid,
  target_quem            text,
  target_texto           text default null,
  target_midia           text default null,
  target_storage_path    text default null,
  target_erro            text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_turn uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  -- A sessão tem que ser deste salão. Sem esta linha, um id de sessão vazado
  -- escreveria conversa dentro de outro negócio.
  if not exists (
    select 1 from app.onboarding_sessions s
     where s.id = target_session_id and s.tenant_id = target_tenant_id and s.status = 'ABERTA'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'SESSAO_NAO_ESTA_ABERTA_NESTE_SALAO');
  end if;

  insert into app.onboarding_turns
    (session_id, tenant_id, quem, texto, midia, storage_path, erro_leitura)
  values
    (target_session_id, target_tenant_id, target_quem,
     nullif(trim(coalesce(target_texto, '')), ''),
     nullif(target_midia, ''), nullif(target_storage_path, ''), nullif(target_erro, ''))
  returning id into v_turn;

  return jsonb_build_object(
    'ok', true,
    'turnId', v_turn,
    -- A pauta inteira vai junto: é ela que impede o modelo de inventar chave.
    -- Sessenta linhas curtas cabem folgado no pedido, e o alternativo -- deixar
    -- o modelo adivinhar o id do serviço -- é o erro que a lista branca
    -- recusaria depois, com a conversa já perdida.
    'pendencias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'chave', p.chave, 'modulo', p.modulo,
               'pergunta', p.pergunta, 'contexto', p.contexto) order by p.prioridade, p.pergunta)
        from (select * from app.onboarding_pendencies(target_tenant_id) limit 60) p
    ), '[]'::jsonb),
    -- O que já foi dito nesta sessão, para o sistema não repetir pergunta.
    'conversa', coalesce((
      select jsonb_agg(jsonb_build_object('quem', t.quem, 'texto', t.texto) order by t.created_at)
        from (select * from app.onboarding_turns t2
               where t2.session_id = target_session_id and t2.texto is not null
               order by t2.created_at desc limit 12) t
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_onboarding_turn(text, text, uuid, uuid, text, text, text, text, text)
  to service_role;

create or replace function public.site_onboarding_record(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_session_id      uuid,
  target_turn_id         uuid,
  target_itens           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_item      jsonb;
  v_resultado jsonb := '[]'::jsonb;
  v_uma       jsonb;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  if not exists (
    select 1 from app.onboarding_sessions s
     where s.id = target_session_id and s.tenant_id = target_tenant_id and s.status = 'ABERTA'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'SESSAO_NAO_ESTA_ABERTA_NESTE_SALAO');
  end if;

  if jsonb_typeof(coalesce(target_itens, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'ITENS_INVALIDOS');
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(target_itens, '[]'::jsonb))
  loop
    -- Item sem chave ou sem o que entendeu não vira linha: registro que não
    -- diz o que mudou é pior que registro nenhum.
    continue when coalesce(trim(v_item->>'chave'), '') = ''
              or coalesce(trim(v_item->>'entendido'), '') = '';

    v_uma := app.onboarding_record_answer(
      target_session_id,
      target_turn_id,
      trim(v_item->>'chave'),
      coalesce(nullif(trim(coalesce(v_item->>'modulo', '')), ''), 'OUTRO'),
      trim(v_item->>'entendido'),
      nullif(trim(coalesce(v_item->>'valorTexto', '')), ''),
      case when (v_item->>'valorNumero') ~ '^-?[0-9]+(\.[0-9]+)?$'
             then (v_item->>'valorNumero')::numeric end,
      case when (v_item->>'confianca') ~ '^[0-9]+(\.[0-9]+)?$'
             then least(1, (v_item->>'confianca')::numeric) end
    );

    v_resultado := v_resultado || jsonb_build_array(
      jsonb_build_object('chave', v_item->>'chave', 'status', v_uma->>'status',
                         'motivo', v_uma->>'motivo', 'id', v_uma->>'id'));
  end loop;

  return jsonb_build_object('ok', true, 'itens', v_resultado);
end;
$function$;

grant execute on function public.site_onboarding_record(text, text, uuid, uuid, uuid, jsonb) to service_role;
