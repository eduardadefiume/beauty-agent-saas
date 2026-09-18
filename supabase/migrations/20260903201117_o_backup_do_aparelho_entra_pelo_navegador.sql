-- O BACKUP DO APARELHO ENTRA PELO NAVEGADOR
--
-- O Coexistence traz 180 dias. O que veio antes disso, e os grupos, só existem
-- no backup local do aparelho: o `msgstore.db.crypt15`. Ele abre com a chave de
-- 64 dígitos que o WhatsApp mostra ao dono.
--
-- ONDE ISSO ABRE, E POR QUÊ
--
-- No navegador dele. Mandar a chave de 64 dígitos para cá seria entregar ao
-- SaaS o que abre TODO backup do WhatsApp daquele salão -- não só o arquivo que
-- ele escolheu importar. E o ganho seria zero: as mensagens já lidas vêm para
-- cá de qualquer jeito. Então o arquivo cifrado e a chave não saem do
-- computador dele; o que chega aqui é conversa já lida.
--
-- IDEMPOTÊNCIA
--
-- Um backup de dois anos não cabe em uma requisição, então ele chega em
-- pedaços. `primeiroPedaco` diz qual pedaço abre a conversa: nele, o que já
-- existia daquela conversa é apagado antes. Sem isso, importar duas vezes
-- dobraria o histórico do salão, e ninguém perceberia olhando a tela.

alter table app.wa_archives drop constraint if exists wa_archives_source_check;
alter table app.wa_archives add constraint wa_archives_source_check
  check (source in ('EXPORT_TXT', 'COEXISTENCE', 'BACKUP_CRYPT15'));

-- A conversa do backup é identificada pelo jid, igual à do Coexistence, mas as
-- duas origens não podem colidir: a mesma cliente pode chegar pelos dois
-- caminhos, e cada um tem o seu recorte de tempo.
create unique index if not exists wa_archives_por_backup_uk
  on app.wa_archives (tenant_id, external_thread_id)
  where source = 'BACKUP_CRYPT15' and external_thread_id is not null;

comment on column app.wa_archives.external_thread_id is
  'O jid da conversa no WhatsApp. Vem do Coexistence ou do msgstore do backup.';

create or replace function public.site_wa_backup_absorb(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  p_conversas            jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_conversa jsonb;
  v_fala     jsonb;
  v_chave    text;
  v_fone     text;
  v_grupo    boolean;
  v_archive  uuid;
  v_contato  uuid;
  v_conversas integer := 0;
  v_mensagens integer := 0;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  -- A mesma tranca do arquivo .txt: sem autorização registrada, o histórico do
  -- salão não entra. Isso é de propósito.
  if not exists (
    select 1 from app.data_authorizations a
     where a.tenant_id = target_tenant_id
       and a.scope = 'HISTORICO_WHATSAPP' and a.revoked_at is null
  ) then
    return jsonb_build_object('ok', false, 'reason', 'SEM_AUTORIZACAO_REGISTRADA');
  end if;

  if jsonb_typeof(p_conversas) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'FORMATO_INVALIDO');
  end if;

  for v_conversa in select value from jsonb_array_elements(p_conversas)
  loop
    v_chave := nullif(trim(coalesce(v_conversa->>'chave', '')), '');
    continue when v_chave is null;

    v_grupo := coalesce((v_conversa->>'ehGrupo')::boolean, false);
    v_fone  := case when v_grupo then null
                    else nullif(regexp_replace(coalesce(v_conversa->>'telefone', ''), '[^0-9]', '', 'g'), '') end;

    v_contato := null;
    if v_fone is not null then
      select c.contact_id into v_contato
        from app.crm_contact_channels c
       where c.tenant_id = target_tenant_id
         and right(regexp_replace(c.address_normalized, '[^0-9]', '', 'g'), 8) = right(v_fone, 8)
       limit 1;
    end if;

    v_archive := null;
    insert into app.wa_archives
      (tenant_id, contact_id, contact_label, phone_digits, source,
       external_thread_id, status, imported_by)
    values
      (target_tenant_id, v_contato,
       coalesce(nullif(trim(coalesce(v_conversa->>'nome', '')), ''), v_fone, v_chave),
       v_fone, 'BACKUP_CRYPT15', v_chave, 'PRONTO', lower(trim(target_email)))
    on conflict (tenant_id, external_thread_id)
      where source = 'BACKUP_CRYPT15' and external_thread_id is not null
      do update set contact_id = coalesce(app.wa_archives.contact_id, excluded.contact_id),
                    contact_label = excluded.contact_label,
                    updated_at = statement_timestamp()
    returning id into v_archive;

    continue when v_archive is null;

    -- O pedaço que abre a conversa limpa o que já havia dela. Reimportar o
    -- mesmo backup passa a ser inofensivo em vez de dobrar tudo.
    if coalesce((v_conversa->>'primeiroPedaco')::boolean, false) then
      delete from app.wa_archive_messages m where m.archive_id = v_archive;
      v_conversas := v_conversas + 1;
    end if;

    for v_fala in select value from jsonb_array_elements(
                    case when jsonb_typeof(v_conversa->'falas') = 'array'
                         then v_conversa->'falas' else '[]'::jsonb end)
    loop
      insert into app.wa_archive_messages
        (tenant_id, archive_id, position, quem, autor_label, texto, sent_at, media_filename)
      values
        (target_tenant_id, v_archive,
         coalesce((v_fala->>'posicao')::integer, 0),
         case when v_fala->>'quem' = 'DONO' then 'DONO' else 'CLIENTE' end,
         null,
         nullif(v_fala->>'texto', ''),
         nullif(v_fala->>'enviadaEm', '')::timestamptz,
         nullif(v_fala->>'midia', ''))
      on conflict (archive_id, position) do update
        set texto = excluded.texto,
            quem = excluded.quem,
            sent_at = excluded.sent_at,
            media_filename = excluded.media_filename;

      v_mensagens := v_mensagens + 1;
    end loop;

    update app.wa_archives a
       set message_count = (select count(*) from app.wa_archive_messages m where m.archive_id = a.id),
           media_count   = (select count(*) from app.wa_archive_messages m
                             where m.archive_id = a.id and m.media_filename is not null),
           first_message_at = (select min(m.sent_at) from app.wa_archive_messages m where m.archive_id = a.id),
           last_message_at  = (select max(m.sent_at) from app.wa_archive_messages m where m.archive_id = a.id),
           updated_at = statement_timestamp()
     where a.id = v_archive;
  end loop;

  return jsonb_build_object('ok', true, 'conversas', v_conversas, 'mensagens', v_mensagens);
end;
$function$;

grant execute on function public.site_wa_backup_absorb(text, text, uuid, jsonb) to service_role;
