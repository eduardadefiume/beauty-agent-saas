-- Importar o histórico do salão como fichas.
--
-- O William trocou de número para entrar na Cloud API, e o CRM começou vazio:
-- quatro contatos. As 471 clientes do histórico dele não existem aqui. Então
-- este importador CRIA contato, canal e ficha -- não casa com o que já está no
-- banco, porque não há com o que casar.
--
-- A CHAVE É O TELEFONE, e por isso ele é a única coluna sem a qual a linha é
-- recusada. Ficha sem telefone é ficha que o agente nunca vai encontrar: quando
-- a cliente mandar mensagem, a busca é pelo número, e um perfil órfão só
-- ocuparia espaço fingindo que o salão está preparado.
--
-- É IDEMPOTENTE. Rodar duas vezes com o mesmo arquivo não duplica ninguém --
-- contato, canal e ficha são resolvidos por telefone, e os procedimentos têm
-- chave única por (ficha, família, rótulo). Isso importa porque um arquivo de
-- 286 linhas quase nunca entra certo na primeira tentativa.
--
-- O QUE ELE NÃO FAZ: não inventa consentimento, não classifica cabelo, e não
-- marca ficha como completa. Tudo que entra por aqui nasce PRE_CADASTRO,
-- porque foi o sistema que deduziu, não o dono que conferiu.

create or replace function public.site_import_clients(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_connection_id   uuid,
  payload                jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_linha      jsonb;
  v_fone       text;
  v_contato_id uuid;
  v_perfil_id  uuid;
  v_nova       boolean;
  v_proc       jsonb;
  v_criadas    integer := 0;
  v_atualizadas integer := 0;
  v_recusadas  integer := 0;
  v_motivos    jsonb := '[]'::jsonb;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  if not exists (select 1 from app.channel_connections c
                  where c.id = target_connection_id and c.tenant_id = target_tenant_id) then
    raise exception 'CONNECTION_NOT_FOUND';
  end if;

  for v_linha in select * from jsonb_array_elements(coalesce(payload->'rows', '[]'::jsonb)) loop
    v_fone := app.normalize_phone(v_linha->>'phone');

    if v_fone is null then
      v_recusadas := v_recusadas + 1;
      v_motivos := v_motivos || jsonb_build_object(
        'name', v_linha->>'name', 'reason', 'TELEFONE_INVALIDO', 'raw', v_linha->>'phone');
      continue;
    end if;

    -- Contato e canal, resolvidos pelo telefone.
    select ch.contact_id into v_contato_id
      from app.crm_contact_channels ch
     where ch.tenant_id = target_tenant_id and ch.address_normalized = v_fone
     limit 1;

    if v_contato_id is null then
      insert into app.crm_contacts (tenant_id, unit_id, display_name, status, external_contact_ref)
      select target_tenant_id,
             (select u.id from app.units u where u.tenant_id = target_tenant_id order by u.created_at limit 1),
             coalesce(nullif(trim(v_linha->>'name'), ''), v_fone),
             'ACTIVE',
             v_fone
      returning id into v_contato_id;

      insert into app.crm_contact_channels (
        tenant_id, contact_id, channel_connection_id, provider, address_normalized, is_primary)
      values (target_tenant_id, v_contato_id, target_connection_id, 'WHATSAPP', v_fone, true)
      on conflict do nothing;
    end if;

    -- A ficha.
    insert into app.client_profiles (
      tenant_id, contact_id, preferred_name, status, tone_wanted, notes)
    values (
      target_tenant_id, v_contato_id,
      nullif(trim(v_linha->>'name'), ''),
      'PRE_CADASTRO',
      nullif(trim(coalesce(v_linha->>'toneCited', '')), ''),
      nullif(trim(coalesce(v_linha->>'notes', '')), ''))
    on conflict (tenant_id, contact_id) do update
      set preferred_name = coalesce(app.client_profiles.preferred_name, excluded.preferred_name),
          tone_wanted    = coalesce(app.client_profiles.tone_wanted, excluded.tone_wanted)
    -- xmax = 0 no RETURNING distingue linha inserida de linha atualizada. Só
    -- funciona dentro do RETURNING; fora dele não há linha de referência.
    returning id, (xmax = 0) into v_perfil_id, v_nova;

    if v_nova then
      v_criadas := v_criadas + 1;
    else
      v_atualizadas := v_atualizadas + 1;
    end if;

    -- Procedimentos e cadência.
    for v_proc in select * from jsonb_array_elements(coalesce(v_linha->'procedures', '[]'::jsonb)) loop
      insert into app.client_procedures (
        tenant_id, profile_id, family, label, times_done, last_done_at,
        cadence_days, cadence_confidence)
      values (
        target_tenant_id, v_perfil_id,
        coalesce(nullif(v_proc->>'family', ''), 'OUTRO')::app.procedure_family,
        trim(v_proc->>'label'),
        coalesce((v_proc->>'timesDone')::integer, 1),
        nullif(v_proc->>'lastDoneAt', '')::date,
        nullif(v_proc->>'cadenceDays', '')::integer,
        coalesce(nullif(v_proc->>'cadenceConfidence', ''), 'BAIXA'))
      on conflict (profile_id, family, label) do update
        set times_done   = greatest(app.client_procedures.times_done, excluded.times_done),
            cadence_days = coalesce(excluded.cadence_days, app.client_procedures.cadence_days),
            last_done_at = greatest(app.client_procedures.last_done_at, excluded.last_done_at);
    end loop;

    -- A última visita conhecida. Só uma: o arquivo traz o último
    -- procedimento, não o histórico completo. Fingir mais visitas do que o
    -- arquivo prova estragaria a cadência que o próprio sistema calcula
    -- depois.
    if coalesce(v_linha->>'lastVisitOn', '') <> '' then
      insert into app.client_visits (
        tenant_id, profile_id, occurred_on, description, family)
      select target_tenant_id, v_perfil_id,
             (v_linha->>'lastVisitOn')::date,
             coalesce(nullif(trim(v_linha->>'lastProcedure'), ''), 'Atendimento'),
             nullif(v_linha->>'lastFamily', '')::app.procedure_family
       where not exists (
         select 1 from app.client_visits x
          where x.profile_id = v_perfil_id
            and x.occurred_on = (v_linha->>'lastVisitOn')::date);
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'criadas', v_criadas,
    'atualizadas', v_atualizadas,
    'recusadas', v_recusadas,
    'motivos', v_motivos);
end;
$function$;

revoke all on function public.site_import_clients(text, text, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.site_import_clients(text, text, uuid, uuid, jsonb) to service_role;
