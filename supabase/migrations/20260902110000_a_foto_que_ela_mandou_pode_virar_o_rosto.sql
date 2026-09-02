-- A foto que ela mandou na conversa pode virar o rosto da ficha -- uma a uma,
-- com consentimento.
--
-- O PEDIDO E A REGRA QUE ELE ESBARRA. A Duda quis usar as fotos que as clientes
-- mandaram no WhatsApp para saber qual Andreia é qual. Só que a regra deste
-- sistema, escrita na própria tela de Clientes, é: "Foto que ela manda no meio
-- da conversa não é guardada -- o agente lê e descarta." Copiar tudo em massa
-- desfaria essa regra em silêncio.
--
-- O DESENHO QUE RESPEITA AS DUAS COISAS:
--
--   1. A lista de candidatas NÃO guarda imagem nenhuma. Ela mostra a data e o
--      que o agente leu na foto -- texto que já existe na mensagem.
--   2. Ver a foto baixa da Meta e devolve ao navegador sem gravar. É a mesma
--      "leitura descartável" de sempre; muda só que quem lê é um olho humano.
--   3. Só o clique em "usar como foto" grava. Uma foto, uma decisão, uma
--      pessoa decidindo.
--   4. E só grava se o consentimento da cliente já estiver marcado na ficha.
--      Sem essa trava, o caminho viraria exatamente a cópia em massa que ele
--      existe para evitar.
--
-- A JANELA É CURTA E NÃO É NOSSA. A Meta apaga a mídia depois de um tempo. Para
-- conversa velha não há o que buscar, e a lista diz isso em vez de oferecer um
-- botão que falha.

-- ---------------------------------------------------------------------------
-- 1. O que ela mandou, e o que o agente entendeu de cada uma.
-- ---------------------------------------------------------------------------
create or replace function public.site_client_photo_candidates(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_profile_id      uuid,
  target_limit           integer default 12
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_contato uuid;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  select p.contact_id into v_contato
    from app.client_profiles p
   where p.id = target_profile_id and p.tenant_id = target_tenant_id;
  if v_contato is null then
    raise exception 'CLIENT_NOT_FOUND';
  end if;

  return coalesce((
    select jsonb_agg(x order by x->>'occurredAt' desc)
      from (
        select jsonb_build_object(
                 'messageId', m.id,
                 'occurredAt', m.occurred_at,
                 -- O que o agente leu. É por aqui que ela reconhece a foto sem
                 -- que o sistema precise ter guardado a imagem.
                 'understanding', left(coalesce(m.media_understanding, ''), 400),
                 -- A Meta apaga a mídia com o tempo. Marcar aqui evita oferecer
                 -- um botão que vai falhar.
                 'provavelmenteExpirada', m.occurred_at < now() - interval '25 days'
               ) as x
          from app.crm_messages m
         where m.tenant_id = target_tenant_id
           and m.direction = 'INBOUND'
           and m.message_type = 'MEDIA'
           and m.metadata_minimized ? 'inboxEventId'
           and m.conversation_id in (
             select c.id from app.crm_conversations c
              where c.tenant_id = target_tenant_id and c.contact_id = v_contato
           )
           -- Só imagem. Áudio, vídeo e documento não viram rosto.
           and exists (
             select 1 from app.inbox_events e
              where e.id = (m.metadata_minimized->>'inboxEventId')::uuid
                and e.payload #>> '{message,image,id}' is not null
           )
         order by m.occurred_at desc
         limit greatest(least(coalesce(target_limit, 12), 30), 1)
      ) candidatas
  ), '[]'::jsonb);
end;
$function$;

revoke all on function public.site_client_photo_candidates(text, text, uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.site_client_photo_candidates(text, text, uuid, uuid, integer)
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. O id da mídia, e só depois de conferir que ela é DESTA cliente.
--
-- Sem esta conferência, um messageId digitado à mão baixaria a foto de outra
-- pessoa. O crachá do tenant sozinho não basta: dentro do mesmo salão, uma
-- ficha não pode puxar a foto da conversa de outra.
-- ---------------------------------------------------------------------------
create or replace function public.site_client_media_id(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_profile_id      uuid,
  target_message_id      uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_contato uuid;
  v_media   text;
  v_mime    text;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  select p.contact_id into v_contato
    from app.client_profiles p
   where p.id = target_profile_id and p.tenant_id = target_tenant_id;
  if v_contato is null then
    raise exception 'CLIENT_NOT_FOUND';
  end if;

  select e.payload #>> '{message,image,id}',
         e.payload #>> '{message,image,mime_type}'
    into v_media, v_mime
    from app.crm_messages m
    join app.crm_conversations c
      on c.id = m.conversation_id and c.tenant_id = m.tenant_id
    join app.inbox_events e
      on e.id = (m.metadata_minimized->>'inboxEventId')::uuid
   where m.id = target_message_id
     and m.tenant_id = target_tenant_id
     and m.direction = 'INBOUND'
     and c.contact_id = v_contato;

  if v_media is null then
    return jsonb_build_object('ok', false, 'reason', 'MENSAGEM_NAO_E_DESTA_CLIENTE');
  end if;
  return jsonb_build_object('ok', true, 'mediaId', v_media,
                            'mimeType', coalesce(v_mime, 'image/jpeg'));
end;
$function$;

revoke all on function public.site_client_media_id(text, text, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.site_client_media_id(text, text, uuid, uuid, uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3. Adotar a foto como rosto da ficha.
--
-- A TRAVA DO CONSENTIMENTO MORA AQUI, e não na tela. Trava de tela é sugestão;
-- trava no banco é regra. Guardar a foto de uma pessoa que não autorizou não
-- pode depender de a tela lembrar de conferir.
-- ---------------------------------------------------------------------------
create or replace function public.site_adopt_client_photo(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_profile_id      uuid,
  target_message_id      uuid,
  target_storage_path    text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_consentiu timestamptz;
  v_antiga    text;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  select photo_consent_granted_at into v_consentiu
    from app.client_profiles
   where id = target_profile_id and tenant_id = target_tenant_id;
  if not found then
    raise exception 'CLIENT_NOT_FOUND';
  end if;
  if v_consentiu is null then
    return jsonb_build_object('ok', false, 'reason', 'SEM_CONSENTIMENTO');
  end if;

  if position(target_tenant_id::text || '/' in target_storage_path) <> 1 then
    raise exception 'STORAGE_PATH_FORA_DO_TENANT';
  end if;

  -- Uma ficha tem um rosto só. O caminho da que sai volta para o site apagar o
  -- arquivo: registro sem arquivo, ou arquivo sem registro, é lixo dos dois
  -- jeitos.
  delete from app.client_photos
   where profile_id = target_profile_id and kind = 'PERFIL'
  returning storage_path into v_antiga;

  insert into app.client_photos (tenant_id, profile_id, kind, storage_path, caption)
  values (target_tenant_id, target_profile_id, 'PERFIL', target_storage_path,
          'Escolhida de uma foto que ela mandou na conversa.');

  return jsonb_build_object('ok', true, 'removedPath', v_antiga);
end;
$function$;

revoke all on function public.site_adopt_client_photo(text, text, uuid, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.site_adopt_client_photo(text, text, uuid, uuid, uuid, text)
  to service_role;
