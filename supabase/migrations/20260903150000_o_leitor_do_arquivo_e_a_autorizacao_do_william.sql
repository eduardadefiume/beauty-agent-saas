-- ETAPA 6, parte 2: quem lê o arquivo, e o registro da autorização.
--
-- A leitura é worker, não requisição: uma conversa de dois anos tem milhares
-- de linhas, e o dono não fica olhando a tela esperando. Mesmo desenho do
-- leitor de altura de tom -- fila no banco, pg_cron acorda, a função de borda
-- lê e devolve.
--
-- `LENDO` existe para o segundo tique não pegar o mesmo arquivo que o
-- primeiro ainda está lendo. Sem isso, uma leitura lenta viraria mensagem
-- duplicada.

create or replace function app.wa_archive_claim(p_limit integer default 3)
returns table (
  archive_id   uuid,
  tenant_id    uuid,
  storage_path text,
  filename     text,
  contact_label text
)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  return query
  with escolhidos as (
    select a.id
      from app.wa_archives a
     where a.status = 'PENDENTE'
       and a.read_attempts < 3
     order by a.created_at
     limit greatest(1, least(coalesce(p_limit, 3), 10))
     for update skip locked
  )
  update app.wa_archives a
     set status = 'LENDO',
         read_attempts = a.read_attempts + 1,
         updated_at = statement_timestamp()
    from escolhidos e
   where a.id = e.id
  returning a.id, a.tenant_id, a.storage_path, a.source_filename, a.contact_label;
end;
$function$;

revoke all on function app.wa_archive_claim(integer) from public, anon, authenticated;
grant execute on function app.wa_archive_claim(integer) to service_role;

-- Grava um pedaço das mensagens lidas. Vem em pedaços porque um arquivo de
-- cinco mil mensagens num payload só é pedido grande demais para a borda.
create or replace function app.wa_archive_write_chunk(
  p_archive_id uuid,
  p_messages   jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tenant uuid;
  v_n      integer;
begin
  select tenant_id into v_tenant from app.wa_archives where id = p_archive_id;
  if v_tenant is null then
    return jsonb_build_object('ok', false, 'reason', 'ARQUIVO_NAO_EXISTE');
  end if;
  if jsonb_typeof(coalesce(p_messages, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'MENSAGENS_INVALIDAS');
  end if;

  insert into app.wa_archive_messages
    (tenant_id, archive_id, position, quem, autor_label, texto, sent_at, media_filename)
  select
    v_tenant, p_archive_id,
    (m->>'position')::integer,
    case when m->>'quem' in ('DONO', 'CLIENTE', 'SISTEMA') then m->>'quem' else 'SISTEMA' end,
    nullif(trim(coalesce(m->>'autor', '')), ''),
    nullif(m->>'texto', ''),
    -- Data ilegível não derruba a linha: a mensagem entra sem data, e é
    -- melhor ter o texto sem quando do que perder os dois.
    case when (m->>'sentAt') ~ '^\d{4}-\d{2}-\d{2}T' then (m->>'sentAt')::timestamptz end,
    nullif(trim(coalesce(m->>'midia', '')), '')
  from jsonb_array_elements(p_messages) as e(m)
  where (m->>'position') ~ '^[0-9]+$'
  on conflict (archive_id, position) do nothing;

  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'gravadas', v_n);
end;
$function$;

revoke all on function app.wa_archive_write_chunk(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.wa_archive_write_chunk(uuid, jsonb) to service_role;

create or replace function app.wa_archive_finish(
  p_archive_id uuid,
  p_error      text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_n integer; v_de timestamptz; v_ate timestamptz; v_midia integer;
begin
  if p_error is not null then
    update app.wa_archives
       set status = case when read_attempts >= 3 then 'FALHOU' else 'PENDENTE' end,
           read_error = left(p_error, 500),
           updated_at = statement_timestamp()
     where id = p_archive_id;
    return jsonb_build_object('ok', true, 'status', 'ERRO_REGISTRADO');
  end if;

  select count(*), min(sent_at), max(sent_at), count(*) filter (where media_filename is not null)
    into v_n, v_de, v_ate, v_midia
    from app.wa_archive_messages where archive_id = p_archive_id;

  update app.wa_archives
     set status = 'PRONTO', message_count = v_n,
         media_count = v_midia,
         first_message_at = v_de, last_message_at = v_ate,
         read_error = null, updated_at = statement_timestamp()
   where id = p_archive_id;

  return jsonb_build_object('ok', true, 'mensagens', v_n, 'comMidia', v_midia);
end;
$function$;

revoke all on function app.wa_archive_finish(uuid, text) from public, anon, authenticated;
grant execute on function app.wa_archive_finish(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- O que a tela lê
-- ---------------------------------------------------------------------------

create or replace function public.site_wa_archives(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  return jsonb_build_object(
    'autorizacao', (
      select jsonb_build_object(
               'autorizadoPor', a.authorized_by, 'quando', a.authorized_at,
               'base', a.legal_basis, 'nota', a.note)
        from app.data_authorizations a
       where a.tenant_id = target_tenant_id
         and a.scope = 'HISTORICO_WHATSAPP' and a.revoked_at is null
    ),
    'resumo', (
      select jsonb_build_object(
               'conversas', count(*),
               'prontas', count(*) filter (where status = 'PRONTO'),
               'naFila', count(*) filter (where status in ('PENDENTE', 'LENDO')),
               'falhas', count(*) filter (where status = 'FALHOU'),
               'semAmarra', count(*) filter (where contact_id is null),
               'mensagens', coalesce(sum(message_count), 0))
        from app.wa_archives where tenant_id = target_tenant_id
    ),
    'conversas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'nome', a.contact_label, 'telefone', a.phone_digits,
               'arquivo', a.source_filename, 'status', a.status,
               'mensagens', a.message_count, 'comMidia', a.media_count,
               'de', a.first_message_at, 'ate', a.last_message_at,
               'erro', a.read_error,
               'contactId', a.contact_id,
               'clienteNoCrm', (select c.display_name from app.crm_contacts c where c.id = a.contact_id)
             ) order by a.last_message_at desc nulls last, a.created_at desc)
        from app.wa_archives a where a.tenant_id = target_tenant_id
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_wa_archives(text, text, uuid) to service_role;

create or replace function public.site_wa_archive_read(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_archive_id      uuid,
  target_offset          integer default 0,
  target_limit           integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  if not exists (
    select 1 from app.wa_archives a
     where a.id = target_archive_id and a.tenant_id = target_tenant_id
  ) then
    return jsonb_build_object('ok', false, 'reason', 'ARQUIVO_NAO_E_DESTE_SALAO');
  end if;

  return jsonb_build_object(
    'ok', true,
    'mensagens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'position', m.position, 'quem', m.quem, 'autor', m.autor_label,
               'texto', m.texto, 'quando', m.sent_at, 'midia', m.media_filename
             ) order by m.position)
        from (
          select * from app.wa_archive_messages
           where archive_id = target_archive_id
           order by position
           offset greatest(0, coalesce(target_offset, 0))
           limit greatest(1, least(coalesce(target_limit, 200), 500))
        ) m
    ), '[]'::jsonb),
    'achados', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', f.kind, 'titulo', f.titulo, 'conteudo', f.conteudo,
               'trecho', f.trecho, 'confianca', f.confidence)
             order by f.kind, f.ocorrencias desc)
        from app.wa_archive_findings f where f.archive_id = target_archive_id
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_wa_archive_read(text, text, uuid, uuid, integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- A autorização do William, registrada
-- ---------------------------------------------------------------------------
--
-- "Já nasce com o consentimento autorizado porque o William já autorizou" --
-- é o que a Duda decidiu, e é o que está gravado aqui. A base declarada não é
-- "as clientes consentiram", porque ninguém consente por outra pessoa: é o
-- salão ser controlador do próprio registro de atendimento, que ele já detém
-- hoje no aparelho dele.

insert into app.data_authorizations
  (tenant_id, scope, authorized_by, recorded_by, legal_basis, note)
select t.id, 'HISTORICO_WHATSAPP',
       'William (dono do salão-piloto)',
       'eddigital.oficial@gmail.com',
       'SALAO_E_CONTROLADOR_DO_PROPRIO_ATENDIMENTO',
       'O dono autorizou trazer o histórico de atendimento do WhatsApp dele para o sistema. A cliente continua podendo pedir exclusão do que é dela, e o pedido alcança este arquivo.'
  from app.tenants t
 where t.slug = 'piloto-eduarda'
on conflict (tenant_id, scope) do nothing;
