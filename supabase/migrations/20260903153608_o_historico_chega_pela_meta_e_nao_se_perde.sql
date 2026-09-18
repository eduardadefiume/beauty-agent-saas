-- ETAPA 6, parte 2: o histórico chega pela Meta, oficialmente.
--
-- O QUE MUDOU DE ENTENDIMENTO. Eu tinha construído a importação conversa por
-- conversa, por arquivo exportado. A Duda recusou, e estava certa: existe
-- caminho oficial. A Meta tem o COEXISTENCE -- o WhatsApp Business App e a
-- Cloud API no mesmo número, ao mesmo tempo -- e, quando o dono autoriza, ela
-- EMPURRA os últimos 180 dias de conversa 1:1 para o nosso webhook, em três
-- fases (dia 0 a 1, dia 1 a 90, dia 90 a 180), mais a lista de contatos dele.
--
-- Para o dono é um clique, no Android e no iPhone igual, porque a sincronização
-- é servidor a servidor: o celular dele não faz nada.
--
-- Três campos de webhook entregam isso:
--   history              o histórico, em fases e pedaços
--   smb_app_state_sync   os contatos, com nome de verdade
--   smb_message_echoes   o que ele digitar no aplicativo de agora em diante
--
-- O DEFEITO QUE ISTO CONSERTA ANTES DE EXISTIR. O `extractWhatsAppEvents` de
-- hoje é tolerante a campo desconhecido: o que ele não entende cai num evento
-- `WHATSAPP_CHANGE_<CAMPO>` -- mas o payload que ele guarda nesse caso é só o
-- sha da entrega, NÃO o conteúdo. Um `history` chegando hoje seria aceito com
-- 200, registrado como "houve uma mudança", e os 180 dias de conversa iriam
-- para o lixo em silêncio. Este arquivo faz a captura crua vir ANTES de
-- qualquer interpretação.
--
-- POR QUE GUARDAR O CRU E SÓ DEPOIS INTERPRETAR. Eu não consegui alcançar a
-- documentação da Meta deste ambiente -- o proxy bloqueia developers.facebook.com
-- -- então a forma exata do payload vem de fontes secundárias. Guardar o cru
-- primeiro é o que transforma "errei a forma" em "reinterpreto amanhã" em vez
-- de "perdi o histórico do salão".

create table if not exists app.wa_coexistence_deliveries (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid references app.tenants(id) on delete cascade,
  waba_id        text not null,
  phone_number_id text,
  field          text not null,
  -- O cru, inteiro, como a Meta mandou. É a rede embaixo de toda
  -- interpretação: se o parser errar, o dado continua aqui.
  value          jsonb not null,
  payload_sha256 text not null,
  -- Fase e pedaço vêm no próprio payload de history. Guardados fora do jsonb
  -- porque é por eles que se sabe se o histórico chegou inteiro.
  phase          integer,
  chunk_order    integer,
  progress       integer,
  parsed_at      timestamptz,
  parse_error    text,
  mensagens_lidas integer not null default 0,
  contatos_lidos  integer not null default 0,
  received_at    timestamptz not null default statement_timestamp(),
  unique (payload_sha256, field)
);

create index if not exists wa_coexistence_a_interpretar_idx
  on app.wa_coexistence_deliveries (received_at)
  where parsed_at is null;

comment on table app.wa_coexistence_deliveries is
  'O payload cru de cada entrega do Coexistence, guardado antes de qualquer interpretação. Se o parser errar a forma, o histórico continua aqui para ser relido.';

-- ---------------------------------------------------------------------------
-- O arquivo passa a aceitar conversa que não veio de arquivo nenhum
-- ---------------------------------------------------------------------------

alter table app.wa_archives
  add column if not exists source text not null default 'EXPORT_TXT',
  add column if not exists external_thread_id text;

alter table app.wa_archives drop constraint if exists wa_archives_source_check;
alter table app.wa_archives add constraint wa_archives_source_check
  check (source in ('EXPORT_TXT', 'COEXISTENCE'));

comment on column app.wa_archives.source is
  'De onde a conversa veio: arquivo .txt que o dono subiu, ou o histórico que a Meta empurrou pelo Coexistence.';

-- Conversa que veio pelo Coexistence não tem arquivo no balde. `storage_path`
-- deixa de ser obrigatório, e a unicidade passa a ser por thread quando é
-- Coexistence -- é o wa_id da cliente que identifica a conversa, não um
-- caminho de arquivo que não existe.
alter table app.wa_archives alter column storage_path drop not null;
alter table app.wa_archives drop constraint if exists wa_archives_tenant_id_storage_path_key;

create unique index if not exists wa_archives_por_arquivo_uk
  on app.wa_archives (tenant_id, storage_path) where storage_path is not null;
create unique index if not exists wa_archives_por_thread_uk
  on app.wa_archives (tenant_id, external_thread_id)
  where source = 'COEXISTENCE' and external_thread_id is not null;

-- `source_filename` também deixa de ser obrigatório pelo mesmo motivo.
alter table app.wa_archives alter column source_filename drop not null;

-- ---------------------------------------------------------------------------
-- Interpretar o histórico
-- ---------------------------------------------------------------------------
--
-- QUEM É QUEM AQUI NÃO É PALPITE. No arquivo .txt eu tinha que deduzir o dono
-- por contagem de mensagens, e empatava. Aqui a Meta manda `from` e `to` com o
-- número: quem enviou do número do salão é o DONO, o resto é a CLIENTE. Some
-- toda a heurística, e some com ela a chance de trocar a voz que se quer
-- aprender.

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

-- ---------------------------------------------------------------------------
-- Os contatos, com nome de gente
-- ---------------------------------------------------------------------------
--
-- Este é o ganho que aparece na hora. Hoje o piloto tem 290 contatos chamados
-- "+55 16 98106-4232", porque foi o que o webhook viu passar. O
-- `smb_app_state_sync` traz a agenda do dono: nome completo e primeiro nome,
-- do jeito que ele salvou. É isso que faz a tela de Clientes parar de ser uma
-- lista de números.
--
-- O nome só é sobrescrito quando o que está lá é um número. Se alguém já
-- corrigiu o nome na mão, a mão ganha da sincronização.

create or replace function app.coexistence_absorb_contacts(
  p_tenant_id uuid,
  p_value     jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_item     jsonb;
  v_fone     text;
  v_nome     text;
  v_contato  uuid;
  v_novos    integer := 0;
  v_renomeados integer := 0;
  v_unidade  uuid;
begin
  select u.id into v_unidade from app.units u where u.tenant_id = p_tenant_id
   order by u.created_at limit 1;

  for v_item in select value from jsonb_array_elements(
                  case when jsonb_typeof(p_value->'state_sync') = 'array'
                       then p_value->'state_sync' else '[]'::jsonb end)
  loop
    continue when coalesce(v_item->>'type', '') <> 'contact';

    v_fone := regexp_replace(
      coalesce(v_item->'contact'->>'phone_number', ''), '[^0-9]', '', 'g');
    continue when length(v_fone) < 8;

    v_nome := nullif(trim(coalesce(
      v_item->'contact'->>'full_name', v_item->'contact'->>'first_name', '')), '');

    v_contato := null;
    select c.contact_id into v_contato
      from app.crm_contact_channels c
     where c.tenant_id = p_tenant_id
       and right(regexp_replace(c.address_normalized, '[^0-9]', '', 'g'), 8) = right(v_fone, 8)
     limit 1;

    if v_contato is null then
      insert into app.crm_contacts (tenant_id, unit_id, display_name, status)
      values (p_tenant_id, v_unidade, coalesce(v_nome, v_fone), 'ACTIVE')
      returning id into v_contato;

      insert into app.crm_contact_channels
        (tenant_id, contact_id, provider, address_normalized, is_primary)
      values (p_tenant_id, v_contato, 'WHATSAPP', v_fone, true)
      on conflict do nothing;

      v_novos := v_novos + 1;

    elsif v_nome is not null then
      -- So troca quando o nome de hoje e um numero. Nome escrito por uma
      -- pessoa nao e sobrescrito por sincronizacao.
      update app.crm_contacts c
         set display_name = v_nome, updated_at = statement_timestamp()
       where c.id = v_contato
         and (c.display_name is null or c.display_name ~ '^[+0-9 ()-]+$')
         and c.display_name is distinct from v_nome;
      if found then v_renomeados := v_renomeados + 1; end if;
    end if;

    -- A conversa do arquivo que estava sem cliente amarrada acha a dona agora.
    update app.wa_archives a
       set contact_id = v_contato, updated_at = statement_timestamp()
     where a.tenant_id = p_tenant_id and a.contact_id is null
       and right(regexp_replace(coalesce(a.phone_digits, ''), '[^0-9]', '', 'g'), 8) = right(v_fone, 8);
  end loop;

  return jsonb_build_object('novos', v_novos, 'renomeados', v_renomeados);
end;
$function$;

revoke all on function app.coexistence_absorb_contacts(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.coexistence_absorb_contacts(uuid, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- A porta que o webhook usa
-- ---------------------------------------------------------------------------
--
-- Guarda o cru, resolve o salao pelo waba_id, e so entao interpreta. Erro de
-- interpretacao fica registrado na linha e nao derruba a entrega: a Meta
-- recebe 200, nao reenvia, e o payload continua aqui para ser relido.
--
-- Ela mora em `public` porque e de la que o PostgREST atende sem perfil de
-- schema; o `api.ingest_whatsapp_webhook` continua sendo o caminho das
-- mensagens do dia a dia.

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
