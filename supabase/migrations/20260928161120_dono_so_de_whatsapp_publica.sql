-- DONO SO DE WHATSAPP PUBLICA.
--
-- 28/09/2026, teste com dono-robo: o dono que faz o cadastro inteiro pelo
-- WhatsApp e nunca entrou no painel nao tem e-mail ligado ao numero. Publicar
-- exigia esse e-mail (DONO_SEM_EMAIL) e o Eddy so podia dizer "a equipe
-- libera". Um dono que so usa WhatsApp nunca publicava sozinho.
--
-- Pedir o e-mail na conversa e criar acesso de dono ao painel com ele foi
-- descartado: um erro de digitacao daria acesso de DONO a um estranho. Aqui a
-- autorizacao e o proprio numero de dono ATIVO em owner_whatsapp -- o mesmo
-- que ja autoriza todo o resto do cadastro pelo Eddy -- e nenhum acesso ao
-- painel e criado.
--
-- 1. O miolo de site_publish_configuration vira private.publicar_rascunho,
--    sem mudar nada do que ele faz. O painel continua passando pela checagem
--    de acesso (require_site_tenant) antes do miolo.
-- 2. onboarding_publicar: numero de dono ativo sem e-mail publica pelo miolo,
--    com canal WHATSAPP. Numero com e-mail segue o caminho de sempre.

create or replace function private.publicar_rascunho(
  p_tenant_id uuid,
  p_expected_revision integer,
  p_correlation_id text,
  p_canal text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  draft_record app.configuration_drafts%rowtype;
  unit_record app.units%rowtype;
  next_version integer;
  snapshot_value jsonb;
  hash_value text;
  new_version_id uuid;
begin
  if p_correlation_id is null
     or length(p_correlation_id) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION_ID';
  end if;

  select configuration_draft.*
    into draft_record
    from app.configuration_drafts configuration_draft
   where configuration_draft.tenant_id = p_tenant_id
     and configuration_draft.status = 'DRAFT'
   order by configuration_draft.revision desc
   limit 1
   for update;

  if draft_record.id is null then
    raise exception using errcode = 'P0002', message = 'SITE_DRAFT_NOT_FOUND';
  end if;

  if draft_record.revision <> p_expected_revision then
    raise exception using errcode = '40001', message = 'CONFIGURATION_REVISION_CONFLICT';
  end if;

  if exists (select 1 from private.configuration_readiness(draft_record.id)) then
    raise exception using errcode = '23514', message = 'CONFIGURATION_NOT_READY';
  end if;

  select unit_value.*
    into unit_record
    from app.units unit_value
   where unit_value.id = draft_record.unit_id
     and unit_value.tenant_id = draft_record.tenant_id
   for update;

  select coalesce(max(version_record.version_number), 0) + 1
    into next_version
    from app.configuration_versions version_record
   where version_record.tenant_id = draft_record.tenant_id
     and version_record.unit_id = draft_record.unit_id;

  snapshot_value := private.build_configuration_snapshot(draft_record.id);
  hash_value := encode(extensions.digest(snapshot_value::text, 'sha256'), 'hex');

  insert into app.configuration_versions (
    tenant_id, unit_id, source_draft_id, version_number,
    snapshot, snapshot_hash, published_by
  ) values (
    draft_record.tenant_id, draft_record.unit_id, draft_record.id,
    next_version, snapshot_value, hash_value, null
  )
  returning id into new_version_id;

  update app.configuration_drafts
     set status = 'PUBLISHED',
         updated_by = null,
         updated_at = statement_timestamp()
   where id = draft_record.id;

  update app.units
     set active_configuration_version_id = new_version_id,
         updated_at = statement_timestamp()
   where id = draft_record.unit_id
     and tenant_id = draft_record.tenant_id;

  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id,
    configuration_version_id, correlation_id, result, metadata_minimized
  ) values (
    draft_record.tenant_id, 'SYSTEM', null, 'CONFIGURATION_PUBLISHED',
    'configuration_version', new_version_id, new_version_id,
    p_correlation_id, 'SUCCESS',
    jsonb_build_object(
      'versionNumber', next_version,
      'snapshotHash', hash_value,
      'channel', p_canal
    )
  );

  return jsonb_build_object(
    'configurationVersionId', new_version_id,
    'versionNumber', next_version,
    'snapshotHash', hash_value
  );
end;
$function$;

revoke all on function private.publicar_rascunho(uuid, integer, text, text) from public, anon, authenticated;

create or replace function public.site_publish_configuration(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  expected_revision integer,
  target_correlation_id text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id,
    target_email,
    target_tenant_id,
    array['OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role]
  );

  return private.publicar_rascunho(target_tenant_id, expected_revision, target_correlation_id, 'SITES');
end;
$function$;

create or replace function app.onboarding_publicar(p_tenant_id uuid, p_phone_digits text, p_confirmacao text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_fone     text := regexp_replace(coalesce(p_phone_digits, ''), '[^0-9]', '', 'g');
  v_email    text;
  v_site     text;
  v_rascunho uuid;
  v_revisao  integer;
  v_pend     jsonb;
  v_res      jsonb;
  v_regras   integer;
  v_so_whatsapp boolean := false;
begin
  if length(v_fone) < 8 then
    return jsonb_build_object('ok', false, 'reason', 'TELEFONE_INVALIDO');
  end if;

  if coalesce(trim(p_confirmacao), '') = '' or length(trim(p_confirmacao)) < 2 then
    return jsonb_build_object('ok', false, 'reason', 'SEM_CONFIRMACAO_DO_DONO');
  end if;

  select o.email_normalized into v_email
    from app.owner_whatsapp o
   where o.tenant_id = p_tenant_id
     and o.status = 'ACTIVE'
     and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8) = right(v_fone, 8)
   limit 1;

  if v_email is null then
    if not exists (
      select 1 from app.owner_whatsapp o
       where o.tenant_id = p_tenant_id and o.status = 'ACTIVE'
         and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8) = right(v_fone, 8)
    ) then
      return jsonb_build_object('ok', false, 'reason', 'NAO_E_O_DONO');
    end if;
    -- Numero de dono ativo, sem e-mail: o numero e a autorizacao.
    v_so_whatsapp := true;
  else
    select si.site_project_id into v_site
      from app.site_identities si
     where si.tenant_id = p_tenant_id
       and si.email_normalized = v_email
       and si.status = 'ACTIVE'
       and si.role in ('OWNER'::app.tenant_role, 'ADMIN'::app.tenant_role)
     limit 1;

    if v_site is null then
      return jsonb_build_object('ok', false, 'reason', 'DONO_SEM_ACESSO_DE_DONO');
    end if;
  end if;

  select d.id, d.revision into v_rascunho, v_revisao
    from app.configuration_drafts d
   where d.tenant_id = p_tenant_id and d.status = 'DRAFT'
   order by d.revision desc
   limit 1;

  if v_rascunho is null then
    select count(*) into v_regras
      from app.agent_policies ap
     where ap.tenant_id = p_tenant_id and ap.status = 'DRAFT' and ap.aguarda_publicacao;

    if v_regras = 0 then
      return jsonb_build_object('ok', false, 'reason', 'NADA_PARA_PUBLICAR');
    end if;

    insert into app.audit_logs (
      tenant_id, actor_type, actor_id, action, entity_type, entity_id,
      configuration_version_id, correlation_id, result, metadata_minimized
    ) values (
      p_tenant_id, 'SYSTEM', null, 'OWNER_PUBLISH_RULES_COMMAND', 'agent_policies',
      null, null, 'eddy-publica-regras-' || p_tenant_id::text, 'SUCCESS',
      jsonb_build_object(
        'canal', 'WHATSAPP',
        'telefoneUltimos4', right(v_fone, 4),
        'donoEmail', v_email,
        'autorizadoPor', case when v_so_whatsapp then 'NUMERO_DO_DONO' else 'EMAIL_DO_DONO' end,
        'palavrasDoDono', left(trim(p_confirmacao), 500),
        'regras', v_regras)
    );

    update app.agent_policies
       set status = 'ACTIVE', aguarda_publicacao = false, updated_at = statement_timestamp()
     where tenant_id = p_tenant_id and status = 'DRAFT' and aguarda_publicacao;

    return jsonb_build_object('ok', true, 'somenteRegras', true, 'regrasPublicadas', v_regras);
  end if;

  v_pend := app.onboarding_pendencias_de_publicacao(p_tenant_id);
  if jsonb_array_length(coalesce(v_pend->'pendencias', '[]'::jsonb)) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'FALTA_COISA',
                              'pendencias', v_pend->'pendencias');
  end if;

  -- A frase do dono entra no registro ANTES da publicacao: se a publicacao
  -- falhar, continua existindo prova de que ele pediu.
  insert into app.audit_logs (
    tenant_id, actor_type, actor_id, action, entity_type, entity_id,
    configuration_version_id, correlation_id, result, metadata_minimized
  ) values (
    p_tenant_id, 'SYSTEM', null, 'OWNER_PUBLISH_COMMAND', 'configuration_draft',
    v_rascunho, null, 'eddy-publica-' || v_rascunho::text, 'SUCCESS',
    jsonb_build_object(
      'canal', 'WHATSAPP',
      'telefoneUltimos4', right(v_fone, 4),
      'donoEmail', v_email,
      'autorizadoPor', case when v_so_whatsapp then 'NUMERO_DO_DONO' else 'EMAIL_DO_DONO' end,
      'palavrasDoDono', left(trim(p_confirmacao), 500),
      'revisao', v_revisao)
  );

  begin
    if v_so_whatsapp then
      v_res := private.publicar_rascunho(
        p_tenant_id, v_revisao, 'eddy-publica-' || v_rascunho::text, 'WHATSAPP');
    else
      v_res := public.site_publish_configuration(
        v_site, v_email, p_tenant_id, v_revisao,
        'eddy-publica-' || v_rascunho::text);
    end if;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'PUBLICACAO_RECUSADA',
                              'detalhe', left(sqlerrm, 300));
  end;

  return jsonb_build_object('ok', true, 'versao', v_res,
                            'semEmail', v_so_whatsapp);
end;
$function$;
