create or replace function public.ingest_whatsapp_coexistence(
  p_waba_id         text,
  p_phone_number_id text,
  p_field           text,
  p_payload_sha256  text,
  p_value           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tenant   uuid;
  v_id       uuid;
  v_r        jsonb;
  v_fase     integer;
  v_pedaco   integer;
  v_progresso integer;
begin
  if p_field not in ('history', 'smb_app_state_sync', 'smb_message_echoes') then
    return jsonb_build_object('ok', false, 'reason', 'CAMPO_FORA_DO_COEXISTENCE');
  end if;

  select c.tenant_id into v_tenant
    from app.channel_connections c
   where c.channel = 'WHATSAPP'
     and (c.external_account_id = p_waba_id
          or (p_phone_number_id <> '' and c.external_sender_id = p_phone_number_id))
   limit 1;

  -- Fase e progresso so existem em history, e vem dentro do primeiro bloco.
  v_fase      := nullif(p_value->'history'->0->'metadata'->>'phase', '')::integer;
  v_pedaco    := nullif(p_value->'history'->0->'metadata'->>'chunk_order', '')::integer;
  v_progresso := nullif(p_value->'history'->0->'metadata'->>'progress', '')::integer;

  -- O cru entra ANTES de qualquer interpretacao. Se o parser abaixo falhar, o
  -- historico do salao continua existindo aqui.
  insert into app.wa_coexistence_deliveries
    (tenant_id, waba_id, phone_number_id, field, value, payload_sha256,
     phase, chunk_order, progress)
  values
    (v_tenant, p_waba_id, nullif(p_phone_number_id, ''), p_field, p_value, p_payload_sha256,
     v_fase, v_pedaco, v_progresso)
  on conflict (payload_sha256, field) do nothing
  returning id into v_id;

  -- Entrega repetida: a Meta reenvia quando nao recebe 200 em tempo. Ja esta
  -- guardada, entao nada a fazer.
  if v_id is null then
    return jsonb_build_object('ok', true, 'duplicada', true);
  end if;

  if v_tenant is null then
    update app.wa_coexistence_deliveries d
       set parse_error = 'WABA_SEM_SALAO_CADASTRADO'
     where d.id = v_id;
    return jsonb_build_object('ok', true, 'reason', 'WABA_SEM_SALAO_CADASTRADO');
  end if;

  begin
    if p_field = 'history' then
      v_r := app.coexistence_absorb_history(v_tenant, p_value);
      update app.wa_coexistence_deliveries d
         set parsed_at = statement_timestamp(),
             mensagens_lidas = coalesce((v_r->>'mensagens')::integer, 0)
       where d.id = v_id;

    elsif p_field = 'smb_app_state_sync' then
      v_r := app.coexistence_absorb_contacts(v_tenant, p_value);
      update app.wa_coexistence_deliveries d
         set parsed_at = statement_timestamp(),
             contatos_lidos = coalesce((v_r->>'novos')::integer, 0)
                            + coalesce((v_r->>'renomeados')::integer, 0)
       where d.id = v_id;

    else
      -- `smb_message_echoes`: o que o dono digita no aplicativo de agora em
      -- diante. A forma exata deste payload nao pude confirmar na fonte
      -- primaria, entao ele fica guardado cru e interpretado depois -- em vez
      -- de inventar um parser e descobrir o erro com o dado ja perdido.
      update app.wa_coexistence_deliveries d
         set parse_error = 'ECO_GUARDADO_SEM_INTERPRETAR'
       where d.id = v_id;
      v_r := jsonb_build_object('guardado', true);
    end if;
  exception when others then
    update app.wa_coexistence_deliveries d
       set parse_error = left(sqlerrm, 500)
     where d.id = v_id;
    return jsonb_build_object('ok', true, 'parseFalhou', true, 'motivo', left(sqlerrm, 200));
  end;

  return jsonb_build_object('ok', true, 'field', p_field, 'resultado', v_r);
end;
$function$;

revoke all on function public.ingest_whatsapp_coexistence(text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.ingest_whatsapp_coexistence(text, text, text, text, jsonb)
  to service_role;

-- A exclusao da cliente nao pode devolver caminho nulo: conversa que veio pelo
-- Coexistence nao tem arquivo no balde, e um nulo na lista faria quem chamou
-- tentar apagar "nada".
create or replace function public.site_forget_contact_history(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_contact_id      uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_caminhos text[] := '{}';
  v_arquivos integer;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  if not exists (
    select 1 from app.crm_contacts c
     where c.id = target_contact_id and c.tenant_id = target_tenant_id
  ) then
    return jsonb_build_object('ok', false, 'reason', 'CONTATO_NAO_E_DESTE_SALAO');
  end if;

  select coalesce(array_agg(x.caminho), '{}') into v_caminhos
    from (
      select a.storage_path as caminho
        from app.wa_archives a
       where a.tenant_id = target_tenant_id and a.contact_id = target_contact_id
         and a.storage_path is not null
      union all
      select m.storage_path
        from app.wa_archive_media m
        join app.wa_archives a on a.id = m.archive_id
       where a.tenant_id = target_tenant_id and a.contact_id = target_contact_id
         and m.storage_path is not null
    ) x;

  delete from app.wa_archives a
   where a.tenant_id = target_tenant_id and a.contact_id = target_contact_id;
  get diagnostics v_arquivos = row_count;

  return jsonb_build_object(
    'ok', true,
    'arquivosApagados', v_arquivos,
    'removedPaths', to_jsonb(v_caminhos));
end;
$function$;

grant execute on function public.site_forget_contact_history(text, text, uuid, uuid) to service_role;
