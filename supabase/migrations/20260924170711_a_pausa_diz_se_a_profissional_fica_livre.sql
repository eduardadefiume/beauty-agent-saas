-- A PAUSA DIZ SE A PROFISSIONAL FICA LIVRE.
--
-- 24/09/2026, teste com dono-robo. "Mechas tem 45 minutos de pausa mas eu fico
-- de olho no papel, nao da pra pegar outra cliente." O Eddy respondeu "anotei:
-- nao da pra encaixar outra cliente" -- e gravou a pausa com
-- releases_member = true, porque onboarding_definir_pausa nao tinha como
-- gravar outra coisa. A agenda encaixaria outra cliente em cima das mechas.
--
-- Agora p_libera diz se a profissional sai (padrao: sim, o caso comum). E uma
-- pausa ja gravada com os mesmos minutos pode ser corrigida, em vez de
-- devolver SERVICO_JA_TEM_PAUSA e deixar o erro no ar.
--
-- A assinatura antiga SAI (drop), nao fica ao lado: foi uma sobrecarga
-- ambigua que calou o registro de custo de 20/09 a 24/09.

drop function if exists public.onboarding_definir_pausa(uuid, text, integer, boolean);
drop function if exists app.onboarding_definir_pausa(uuid, text, integer, boolean);

create function app.onboarding_definir_pausa(
  p_tenant_id uuid,
  p_servico text,
  p_minutos integer,
  p_dentro_do_total boolean default true,
  p_libera boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_nome      text := nullif(trim(coalesce(p_servico, '')), '');
  v_libera    boolean := coalesce(p_libera, true);
  v_rascunho  uuid;
  v_servico   uuid;
  v_ativa     record;
  v_pausa     record;
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

  -- Uma pausa so por servico. Se ja existe com os mesmos minutos, isto e uma
  -- correcao de quem fica livre -- grava. Com minutos diferentes, e outra
  -- conversa (as etapas mudam) e fica recusado como antes.
  select t.id, t.duration_minutes into v_pausa
    from app.service_steps t
   where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho
     and t.service_id = v_servico and t.kind = 'PASSIVE'
   limit 1;

  if v_pausa.id is not null then
    if v_pausa.duration_minutes = p_minutos then
      update app.service_steps
         set releases_member = v_libera, updated_at = statement_timestamp()
       where id = v_pausa.id;
      return jsonb_build_object(
        'ok', true, 'servico', v_nome, 'pausaMinutos', p_minutos,
        'corrigida', true, 'liberaProfissional', v_libera);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'SERVICO_JA_TEM_PAUSA', 'servico', v_nome,
                              'pausaAtual', v_pausa.duration_minutes);
  end if;

  select count(*) into v_quantas
    from app.service_steps t
   where t.tenant_id = p_tenant_id and t.configuration_draft_id = v_rascunho
     and t.service_id = v_servico and t.kind = 'ACTIVE';

  if v_quantas <> 1 then
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
    -- A cliente fica. A profissional sai so se o dono disse que sai.
    true, v_libera
  );

  return jsonb_build_object(
    'ok', true, 'servico', v_nome, 'pausaMinutos', p_minutos,
    'dentroDoTotal', p_dentro_do_total,
    'atendimentoMinutos', v_nova_ativa,
    'totalMinutos', v_nova_ativa + p_minutos,
    'liberaProfissional', v_libera
  );
end;
$function$;

revoke all on function app.onboarding_definir_pausa(uuid, text, integer, boolean, boolean) from public, anon, authenticated;

create function public.onboarding_definir_pausa(
  p_tenant_id uuid, p_servico text, p_minutos integer,
  p_dentro_do_total boolean default true, p_libera boolean default true
)
returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_definir_pausa(p_tenant_id, p_servico, p_minutos, p_dentro_do_total, p_libera); $$;

revoke all on function public.onboarding_definir_pausa(uuid, text, integer, boolean, boolean) from public, anon, authenticated;
grant execute on function public.onboarding_definir_pausa(uuid, text, integer, boolean, boolean) to service_role;
