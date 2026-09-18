create or replace function app.coexistence_absorb_history(
  p_tenant_id uuid,
  p_value     jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_meu_numero text;
  v_bloco      jsonb;
  v_thread     jsonb;
  v_msg        jsonb;
  v_wa_id      text;
  v_archive    uuid;
  v_pos        integer;
  v_quem       text;
  v_texto      text;
  v_midia      text;
  v_mensagens  integer := 0;
  v_conversas  integer := 0;
  v_contato    uuid;
begin
  -- O numero do salao, so digitos: e ele que separa o que ele disse do que ela
  -- disse. Sem heuristica de nome.
  v_meu_numero := regexp_replace(
    coalesce(p_value->'metadata'->>'display_phone_number', ''), '[^0-9]', '', 'g');

  for v_bloco in select value from jsonb_array_elements(
                   case when jsonb_typeof(p_value->'history') = 'array'
                        then p_value->'history' else '[]'::jsonb end)
  loop
    for v_thread in select value from jsonb_array_elements(
                      case when jsonb_typeof(v_bloco->'threads') = 'array'
                           then v_bloco->'threads' else '[]'::jsonb end)
    loop
      v_wa_id := regexp_replace(coalesce(v_thread->>'id', ''), '[^0-9]', '', 'g');
      continue when v_wa_id = '';

      -- Amarra na cliente do CRM pelos ultimos 8 digitos, igual ao caminho do
      -- arquivo: e essa amarra que faz o pedido de exclusao dela alcancar o
      -- historico.
      v_contato := null;
      select c.contact_id into v_contato
        from app.crm_contact_channels c
       where c.tenant_id = p_tenant_id
         and right(regexp_replace(c.address_normalized, '[^0-9]', '', 'g'), 8) = right(v_wa_id, 8)
       limit 1;

      v_archive := null;
      insert into app.wa_archives
        (tenant_id, contact_id, contact_label, phone_digits, source,
         external_thread_id, status, imported_by)
      values
        (p_tenant_id, v_contato, v_wa_id, v_wa_id, 'COEXISTENCE',
         v_wa_id, 'PRONTO', 'coexistence@meta')
      on conflict (tenant_id, external_thread_id)
        where source = 'COEXISTENCE' and external_thread_id is not null
        do update set contact_id = coalesce(app.wa_archives.contact_id, excluded.contact_id),
                      updated_at = statement_timestamp()
      returning id into v_archive;

      if v_archive is null then
        select a.id into v_archive from app.wa_archives a
         where a.tenant_id = p_tenant_id and a.external_thread_id = v_wa_id
           and a.source = 'COEXISTENCE';
      end if;
      continue when v_archive is null;

      v_conversas := v_conversas + 1;

      -- A posicao continua de onde parou: as tres fases chegam separadas, e a
      -- fase 2 (mais antiga) chega depois da fase 0. Reordenar por data na
      -- leitura resolve a cronologia; a posicao so precisa ser unica.
      select coalesce(max(m.position), -1) + 1 into v_pos
        from app.wa_archive_messages m where m.archive_id = v_archive;

      for v_msg in select value from jsonb_array_elements(
                     case when jsonb_typeof(v_thread->'messages') = 'array'
                          then v_thread->'messages' else '[]'::jsonb end)
      loop
        v_quem := case
          when v_meu_numero <> ''
           and regexp_replace(coalesce(v_msg->>'from', ''), '[^0-9]', '', 'g') = v_meu_numero
            then 'DONO' else 'CLIENTE' end;

        -- O texto vive em lugares diferentes por tipo. Legenda de imagem e
        -- texto que a cliente escreveu, entao conta.
        v_texto := coalesce(
          v_msg->'text'->>'body',
          v_msg->'image'->>'caption',
          v_msg->'video'->>'caption',
          v_msg->'document'->>'caption',
          v_msg->'button'->>'text',
          v_msg->'interactive'->'button_reply'->>'title');

        -- O id da midia na Meta. Guardado no lugar do nome de arquivo: e por
        -- ele que a imagem pode ser baixada depois.
        v_midia := coalesce(
          v_msg->'image'->>'id', v_msg->'audio'->>'id',
          v_msg->'video'->>'id', v_msg->'document'->>'id',
          v_msg->'sticker'->>'id');

        insert into app.wa_archive_messages
          (tenant_id, archive_id, position, quem, autor_label, texto, sent_at, media_filename)
        values
          (p_tenant_id, v_archive, v_pos, v_quem,
           case when v_quem = 'DONO' then v_meu_numero else v_wa_id end,
           nullif(v_texto, ''),
           case when (v_msg->>'timestamp') ~ '^[0-9]+$'
                then to_timestamp((v_msg->>'timestamp')::bigint) end,
           v_midia)
        on conflict (archive_id, position) do nothing;

        v_pos := v_pos + 1;
        v_mensagens := v_mensagens + 1;
      end loop;

      -- O resumo da conversa e recontado do zero: as fases vao somando.
      update app.wa_archives a
         set message_count = (select count(*) from app.wa_archive_messages m where m.archive_id = a.id),
             media_count   = (select count(*) from app.wa_archive_messages m
                               where m.archive_id = a.id and m.media_filename is not null),
             first_message_at = (select min(m.sent_at) from app.wa_archive_messages m where m.archive_id = a.id),
             last_message_at  = (select max(m.sent_at) from app.wa_archive_messages m where m.archive_id = a.id),
             updated_at = statement_timestamp()
       where a.id = v_archive;
    end loop;
  end loop;

  return jsonb_build_object('mensagens', v_mensagens, 'conversas', v_conversas);
end;
$function$;

revoke all on function app.coexistence_absorb_history(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.coexistence_absorb_history(uuid, jsonb) to service_role;
