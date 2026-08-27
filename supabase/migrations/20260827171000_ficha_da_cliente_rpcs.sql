-- Leitura e gravação da ficha, e a importação do histórico.

-- Telefone é a chave de tudo: é por ele que o agente reconhece quem chegou.
-- Guardar só dígitos evita que "(16) 99412-7035" e "5516994127035" virem duas
-- clientes diferentes. Menos de dez dígitos não é telefone brasileiro válido e
-- é devolvido nulo, para a importação recusar a linha em vez de criar uma
-- ficha que nunca vai casar com ninguém.
create or replace function app.normalize_phone(p_raw text)
returns text
language sql
immutable
as $function$
  select case
    when length(regexp_replace(coalesce(p_raw, ''), '[^0-9]', '', 'g')) >= 10
      then regexp_replace(p_raw, '[^0-9]', '', 'g')
    else null
  end;
$function$;

-- O que falta numa ficha para ela deixar de ser rascunho. É uma função e não
-- uma coluna calculada porque a resposta muda quando o salão cadastra a régua:
-- antes disso, cobrar classificação de cabelo seria cobrar o impossível.
create or replace function app.client_profile_pendencias(p_profile app.client_profiles)
returns text[]
language sql
stable
security definer
set search_path to ''
as $function$
  select array_remove(array[
    case when coalesce(trim(p_profile.preferred_name), '') = '' then 'NOME' end,
    case when p_profile.has_chemistry is null then 'QUIMICA' end,
    case when p_profile.photo_consent_granted_at is null then 'CONSENTIMENTO' end,
    case when p_profile.length_option_id is null and p_profile.thickness_option_id is null
              and exists (select 1 from app.knowledge_dimensions d
                           where d.tenant_id = p_profile.tenant_id and d.status = 'ACTIVE')
         then 'CLASSIFICACAO' end,
    case when not exists (select 1 from app.client_procedures c where c.profile_id = p_profile.id)
         then 'PROCEDIMENTOS' end
  ], null);
$function$;

-- ------------------------------------------------------------------ a fila

-- A ordem da fila é a decisão de produto desta tela.
--
-- São 100 fichas por preencher e ninguém preenche 100 numa tarde. Ordenar por
-- nome ou por data de cadastro faria o dono gastar o esforço dele em cima de
-- quem talvez nunca volte. Ordenado por PRÓXIMO HORÁRIO MARCADO, o esforço cai
-- primeiro em cima de quem chega primeiro -- e a ficha fica pronta antes de
-- ser necessária, que é o único momento em que ela vale alguma coisa.
--
-- Depois de quem tem horário, vem quem está atrasada segundo a própria
-- cadência: essa é a lista de quem o salão deveria estar chamando de volta.
create or replace function public.site_load_clients(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_limit           integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_limite integer := least(greatest(coalesce(target_limit, 200), 1), 500);
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return jsonb_build_object(
    'clients', coalesce((
      select jsonb_agg(item order by
               -- Quem tem horário marcado sobe, do mais próximo ao mais longe.
               (item->>'nextAppointmentAt') is null,
               item->>'nextAppointmentAt',
               -- Depois, quem está mais atrasada em relação à própria cadência.
               (item->>'overdueDays')::integer desc nulls last,
               item->>'name')
        from (
          select jsonb_build_object(
                   'profileId', p.id,
                   'contactId', p.contact_id,
                   'name', coalesce(nullif(trim(p.preferred_name), ''), c.display_name, 'Sem nome'),
                   'phone', ch.address_normalized,
                   'status', p.status,
                   'pendencias', to_jsonb(app.client_profile_pendencias(p)),
                   'totalVisits', (select count(*) from app.client_visits v where v.profile_id = p.id),
                   'lastVisitOn', (select max(v.occurred_on)::text from app.client_visits v where v.profile_id = p.id),
                   'mainProcedure', (
                     select pr.label from app.client_procedures pr
                      where pr.profile_id = p.id
                      order by pr.times_done desc, pr.label limit 1
                   ),
                   'cadenceDays', (
                     select pr.cadence_days from app.client_procedures pr
                      where pr.profile_id = p.id and pr.cadence_days is not null
                      order by pr.times_done desc limit 1
                   ),
                   -- Dias além da cadência: quanto ela já passou do ponto de
                   -- voltar. Negativo significa que ainda está no prazo. Nulo
                   -- quando não há cadência ou não há visita -- e nulo desce
                   -- na ordenação, porque não dá para cobrar retorno de quem
                   -- o sistema nunca viu voltar.
                   'overdueDays', (
                     select (current_date
                             - (select max(v.occurred_on) from app.client_visits v where v.profile_id = p.id))
                            - min(pr.cadence_days)
                       from app.client_procedures pr
                      where pr.profile_id = p.id and pr.cadence_days is not null
                   ),
                   'nextAppointmentAt', (
                     select min(a.starts_at)::text
                       from app.appointments a
                      where a.tenant_id = p.tenant_id
                        and a.starts_at >= statement_timestamp()
                        and a.status <> 'CANCELLED'
                        and a.external_contact_ref is not null
                        and a.external_contact_ref = c.external_contact_ref
                   )
                 ) as item
            from app.client_profiles p
            join app.crm_contacts c on c.id = p.contact_id
            left join app.crm_contact_channels ch
              on ch.contact_id = c.id and ch.is_primary
           where p.tenant_id = target_tenant_id and p.status <> 'ARQUIVADA'
           limit v_limite
        ) pronto
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.site_load_clients(text, text, uuid, integer) from public, anon, authenticated;
grant execute on function public.site_load_clients(text, text, uuid, integer) to service_role;

-- ------------------------------------------------------------- uma ficha

create or replace function public.site_load_client(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_profile_id      uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_perfil app.client_profiles;
  v_contato app.crm_contacts;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  select * into v_perfil from app.client_profiles
   where id = target_profile_id and tenant_id = target_tenant_id;
  if not found then
    raise exception 'CLIENT_NOT_FOUND';
  end if;
  select * into v_contato from app.crm_contacts where id = v_perfil.contact_id;

  return jsonb_build_object(
    'profileId', v_perfil.id,
    'contactId', v_perfil.contact_id,
    'displayName', v_contato.display_name,
    'phone', (select ch.address_normalized from app.crm_contact_channels ch
               where ch.contact_id = v_perfil.contact_id order by ch.is_primary desc limit 1),
    'preferredName', v_perfil.preferred_name,
    'status', v_perfil.status,
    'pendencias', to_jsonb(app.client_profile_pendencias(v_perfil)),
    'lengthOptionId', v_perfil.length_option_id,
    'thicknessOptionId', v_perfil.thickness_option_id,
    'hasChemistry', v_perfil.has_chemistry,
    'chemistryKind', v_perfil.chemistry_kind,
    'chemistryLastAt', v_perfil.chemistry_last_at,
    'chemistryFormol', v_perfil.chemistry_formol,
    'hasColor', v_perfil.has_color,
    'colorLastAt', v_perfil.color_last_at,
    'toneWanted', v_perfil.tone_wanted,
    'photoConsentGrantedAt', v_perfil.photo_consent_granted_at,
    'photoConsentRecordedBy', v_perfil.photo_consent_recorded_by,
    'notes', v_perfil.notes,
    'procedures', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pr.id, 'family', pr.family, 'label', pr.label,
               'timesDone', pr.times_done, 'lastDoneAt', pr.last_done_at,
               'cadenceDays', pr.cadence_days, 'cadenceConfidence', pr.cadence_confidence
             ) order by pr.times_done desc, pr.label)
        from app.client_procedures pr where pr.profile_id = v_perfil.id
    ), '[]'::jsonb),
    'visits', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'occurredOn', v.occurred_on, 'description', v.description,
               'family', v.family, 'durationMinutes', v.duration_minutes,
               'amountCents', v.amount_cents, 'notes', v.notes
             ) order by v.occurred_on desc)
        from app.client_visits v where v.profile_id = v_perfil.id
    ), '[]'::jsonb),
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'kind', f.kind, 'storagePath', f.storage_path,
               'caption', f.caption, 'takenOn', f.taken_on
             ) order by f.kind, f.position, f.created_at)
        from app.client_photos f where f.profile_id = v_perfil.id
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.site_load_client(text, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.site_load_client(text, text, uuid, uuid) to service_role;

-- ------------------------------------------------------------- gravação

-- Grava o perfil e substitui procedimentos, visitas e fotos pelo que veio.
-- Substituição inteira, e não remendo campo a campo, pelo mesmo motivo do
-- rascunho de configuração: a tela mostra o conjunto todo, então o que ela
-- devolve É o conjunto todo. Remendo parcial cria estado que ninguém viu.
--
-- Devolve `removedPaths`: o Supabase proíbe apagar de storage.objects por SQL,
-- então quem chama é que apaga os arquivos pela API de Storage.
create or replace function public.site_save_client(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_profile_id      uuid,
  payload                jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_perfil app.client_profiles;
  v_item jsonb;
  v_removidas text[];
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  select * into v_perfil from app.client_profiles
   where id = target_profile_id and tenant_id = target_tenant_id;
  if not found then
    raise exception 'CLIENT_NOT_FOUND';
  end if;

  -- Consentimento: o carimbo de data nasce aqui, no servidor, e não vem da
  -- tela. Data de consentimento que o navegador escolhe não é prova de nada.
  update app.client_profiles set
    preferred_name = nullif(trim(coalesce(payload->>'preferredName', '')), ''),
    status = case when coalesce(payload->>'status', '') in ('PRE_CADASTRO', 'COMPLETO', 'ARQUIVADA')
                  then payload->>'status' else status end,
    length_option_id = nullif(payload->>'lengthOptionId', '')::uuid,
    thickness_option_id = nullif(payload->>'thicknessOptionId', '')::uuid,
    has_chemistry = case when payload ? 'hasChemistry' then (payload->>'hasChemistry')::boolean end,
    chemistry_kind = nullif(trim(coalesce(payload->>'chemistryKind', '')), ''),
    chemistry_last_at = nullif(payload->>'chemistryLastAt', '')::date,
    chemistry_formol = nullif(payload->>'chemistryFormol', ''),
    has_color = case when payload ? 'hasColor' then (payload->>'hasColor')::boolean end,
    color_last_at = nullif(payload->>'colorLastAt', '')::date,
    tone_wanted = nullif(trim(coalesce(payload->>'toneWanted', '')), ''),
    notes = nullif(trim(coalesce(payload->>'notes', '')), ''),
    photo_consent_granted_at = case
      when coalesce((payload->>'photoConsent')::boolean, false)
        then coalesce(photo_consent_granted_at, statement_timestamp())
      else null end,
    photo_consent_recorded_by = case
      when coalesce((payload->>'photoConsent')::boolean, false) then target_email else null end,
    photo_consent_note = nullif(trim(coalesce(payload->>'photoConsentNote', '')), '')
  where id = target_profile_id;

  delete from app.client_procedures where profile_id = target_profile_id;
  for v_item in select * from jsonb_array_elements(coalesce(payload->'procedures', '[]'::jsonb)) loop
    insert into app.client_procedures (
      tenant_id, profile_id, family, label, times_done, last_done_at,
      cadence_days, cadence_confidence)
    values (
      target_tenant_id, target_profile_id,
      coalesce(nullif(v_item->>'family', ''), 'OUTRO')::app.procedure_family,
      trim(v_item->>'label'),
      coalesce((v_item->>'timesDone')::integer, 1),
      nullif(v_item->>'lastDoneAt', '')::date,
      nullif(v_item->>'cadenceDays', '')::integer,
      coalesce(nullif(v_item->>'cadenceConfidence', ''), 'BAIXA'))
    on conflict (profile_id, family, label) do nothing;
  end loop;

  delete from app.client_visits where profile_id = target_profile_id and appointment_id is null;
  for v_item in select * from jsonb_array_elements(coalesce(payload->'visits', '[]'::jsonb)) loop
    insert into app.client_visits (
      tenant_id, profile_id, occurred_on, description, family,
      duration_minutes, amount_cents, notes)
    values (
      target_tenant_id, target_profile_id,
      (v_item->>'occurredOn')::date,
      coalesce(nullif(trim(v_item->>'description'), ''), 'Atendimento'),
      nullif(v_item->>'family', '')::app.procedure_family,
      nullif(v_item->>'durationMinutes', '')::integer,
      nullif(v_item->>'amountCents', '')::integer,
      nullif(trim(coalesce(v_item->>'notes', '')), ''));
  end loop;

  select coalesce(array_agg(f.storage_path), '{}')
    into v_removidas
    from app.client_photos f
   where f.profile_id = target_profile_id
     and f.storage_path not in (
       select x->>'storagePath' from jsonb_array_elements(coalesce(payload->'photos', '[]'::jsonb)) x
       where coalesce(x->>'storagePath', '') <> ''
     );

  delete from app.client_photos where profile_id = target_profile_id;
  for v_item in select * from jsonb_array_elements(coalesce(payload->'photos', '[]'::jsonb)) loop
    insert into app.client_photos (
      tenant_id, profile_id, kind, storage_path, caption, taken_on, position)
    values (
      target_tenant_id, target_profile_id,
      coalesce(nullif(v_item->>'kind', ''), 'RESULTADO'),
      v_item->>'storagePath',
      nullif(trim(coalesce(v_item->>'caption', '')), ''),
      nullif(v_item->>'takenOn', '')::date,
      coalesce((v_item->>'position')::integer, 0))
    on conflict (tenant_id, storage_path) do nothing;
  end loop;

  return jsonb_build_object('ok', true, 'removedPaths', to_jsonb(v_removidas));
end;
$function$;

revoke all on function public.site_save_client(text, text, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.site_save_client(text, text, uuid, uuid, jsonb) to service_role;
