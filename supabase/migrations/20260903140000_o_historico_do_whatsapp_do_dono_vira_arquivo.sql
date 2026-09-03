-- ETAPA 6, parte 1: o histórico do WhatsApp do dono vira arquivo consultável.
--
-- O QUE A DUDA DECIDIU, E QUE ESTE ARQUIVO IMPLEMENTA:
--   1. Extrair TUDO -- mensagem dele e da cliente, pergunta, resposta, quebra
--      de objeção, explicação técnica, imagem que a cliente mandou.
--   2. Guardar como backup consultável, para nunca precisar reimportar.
--   3. Já nasce autorizado, porque o William autorizou.
--
-- UMA CORREÇÃO NECESSÁRIA NO ITEM 3, E ELA MUDA O CÓDIGO. O William autoriza
-- o uso do que é dele. Ele não consente pelas clientes -- ninguém consente por
-- outra pessoa. Mas o consentimento delas não é a base certa aqui: o salão é o
-- CONTROLADOR desse histórico. Ele já detém essas conversas hoje, no aparelho
-- dele; trazê-las para o sistema dele não muda quem controla.
--
-- A consequência disso é engenharia, não papel: o direito da cliente de pedir
-- exclusão sobrevive a qualquer autorização do dono. Então "apagar os dados da
-- fulana" TEM que alcançar o histórico importado, e é por isso que cada
-- conversa importada nasce amarrada ao contato do CRM. Sem essa amarra,
-- guardar tudo seria guardar o que ninguém consegue apagar.
--
-- POR QUE NÃO ENTRA EM `crm_messages`. Aquelas mensagens alimentam o agente
-- ao vivo: ele lê as últimas e responde. Despejar dois anos de histórico ali
-- faria o agente responder a uma pergunta de 2024 como se fosse de agora.
-- Arquivo é arquivo, conversa viva é conversa viva.

-- ---------------------------------------------------------------------------
-- Quem autorizou trazer o material
-- ---------------------------------------------------------------------------

create table if not exists app.data_authorizations (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  scope        text not null check (scope in ('HISTORICO_WHATSAPP')),
  -- Quem no salão autorizou, com nome, e quem registrou aqui.
  authorized_by      text not null,
  authorized_at      timestamptz not null default statement_timestamp(),
  recorded_by        text,
  -- A base pela qual o dado é tratado. Não é enfeite: é o que responde
  -- "por que vocês têm isso?" no dia em que alguém perguntar.
  legal_basis        text not null default 'SALAO_E_CONTROLADOR_DO_PROPRIO_ATENDIMENTO',
  note               text,
  revoked_at         timestamptz,
  created_at         timestamptz not null default statement_timestamp(),
  unique (tenant_id, scope)
);

comment on table app.data_authorizations is
  'Quem autorizou trazer material para dentro do sistema, quando, e sob que base. O salão é controlador do próprio histórico de atendimento; a cliente continua podendo pedir exclusão do que é dela.';

-- ---------------------------------------------------------------------------
-- O arquivo
-- ---------------------------------------------------------------------------

create table if not exists app.wa_archives (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  -- A amarra que torna a exclusão possível. Pode nascer nula quando o telefone
  -- do arquivo não bate com nenhum contato; a tela mostra esses casos para
  -- alguém amarrar na mão.
  contact_id   uuid references app.crm_contacts(id) on delete set null,
  -- Como a pessoa aparece DENTRO do arquivo exportado. Nem sempre é o nome do
  -- CRM: o WhatsApp usa o nome que está na agenda do celular do dono.
  contact_label text not null,
  phone_digits  text,
  source_filename text not null,
  storage_path    text not null,
  status       text not null default 'PENDENTE'
               check (status in ('PENDENTE', 'LENDO', 'PRONTO', 'FALHOU')),
  message_count   integer not null default 0,
  media_count     integer not null default 0,
  first_message_at timestamptz,
  last_message_at  timestamptz,
  read_attempts   integer not null default 0,
  read_error      text,
  imported_by     text,
  created_at      timestamptz not null default statement_timestamp(),
  updated_at      timestamptz not null default statement_timestamp(),
  unique (tenant_id, storage_path)
);

create index if not exists wa_archives_por_contato_idx
  on app.wa_archives (tenant_id, contact_id);
create index if not exists wa_archives_a_ler_idx
  on app.wa_archives (status, created_at) where status in ('PENDENTE', 'LENDO');

create table if not exists app.wa_archive_messages (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references app.tenants(id) on delete cascade,
  archive_id  uuid not null references app.wa_archives(id) on delete cascade,
  position    integer not null,
  -- DONO, CLIENTE ou SISTEMA (as linhas que o próprio WhatsApp escreve, como
  -- o aviso de criptografia). Guardar as três separadas é o que permite ler
  -- "só o que ele respondeu" sem adivinhar por nome.
  quem        text not null check (quem in ('DONO', 'CLIENTE', 'SISTEMA')),
  autor_label text,
  texto       text,
  sent_at     timestamptz,
  -- O nome do arquivo como aparece no export ("IMG-20240712-WA0003.jpg").
  -- Fica mesmo quando a imagem não veio junto: é a pista de que existiu.
  media_filename text,
  media_id    uuid,
  created_at  timestamptz not null default statement_timestamp(),
  unique (archive_id, position)
);

create index if not exists wa_archive_messages_por_arquivo_idx
  on app.wa_archive_messages (archive_id, position);
create index if not exists wa_archive_messages_busca_idx
  on app.wa_archive_messages using gin (to_tsvector('portuguese', coalesce(texto, '')));

create table if not exists app.wa_archive_media (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  archive_id   uuid not null references app.wa_archives(id) on delete cascade,
  filename     text not null,
  storage_path text not null,
  mime_type    text,
  bytes        integer,
  created_at   timestamptz not null default statement_timestamp(),
  unique (archive_id, filename)
);

comment on table app.wa_archive_media is
  'As imagens e áudios que vieram no export. Ficam no balde `clientes`, que é o balde que morre quando a pessoa pede exclusão.';

-- ---------------------------------------------------------------------------
-- O que a leitura extraiu
-- ---------------------------------------------------------------------------

create table if not exists app.wa_archive_findings (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references app.tenants(id) on delete cascade,
  archive_id  uuid references app.wa_archives(id) on delete cascade,
  kind        text not null check (kind in (
                'PERGUNTA_DA_CLIENTE', 'RESPOSTA_DO_DONO', 'OBJECAO',
                'QUEBRA_DE_OBJECAO', 'EXPLICACAO_TECNICA', 'CONDUCAO_PARA_AGENDA',
                'PRECO_CITADO', 'REGRA_IMPLICITA', 'TOM_DE_VOZ')),
  titulo      text not null,
  conteudo    text not null,
  -- O trecho literal de onde saiu. Sem ele, um padrão extraído é palpite sem
  -- endereço, e ninguém consegue conferir se a leitura foi honesta.
  trecho      text,
  ocorrencias integer not null default 1,
  confidence  numeric(4,3) check (confidence is null or (confidence >= 0 and confidence <= 1)),
  created_at  timestamptz not null default statement_timestamp()
);

create index if not exists wa_archive_findings_por_tipo_idx
  on app.wa_archive_findings (tenant_id, kind, ocorrencias desc);

-- ---------------------------------------------------------------------------
-- O balde passa a aceitar o export
-- ---------------------------------------------------------------------------
--
-- O export vai para `clientes` e não para `conhecimento`, e isso é a decisão
-- que faz a exclusão funcionar: `clientes` é o balde do dado de uma pessoa,
-- que morre quando ela pede. Um histórico de conversa é dado dela.
--
-- O teto sobe porque conversa de dois anos com mídia passa fácil de 8 MB. A
-- rota de upload continua conferindo o teto POR TIPO: foto de ficha segue
-- limitada a 8 MB, e só o export pode usar o espaço maior.

update storage.buckets
   set allowed_mime_types = array[
         'image/jpeg', 'image/png', 'image/webp',
         'text/plain', 'application/zip', 'application/x-zip-compressed',
         'audio/mpeg', 'audio/ogg', 'audio/mp4', 'video/mp4'
       ],
       file_size_limit = 134217728
 where id = 'clientes';

-- ---------------------------------------------------------------------------
-- Registrar o arquivo enviado
-- ---------------------------------------------------------------------------

create or replace function public.site_wa_archive_add(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_storage_path    text,
  target_filename        text,
  target_contact_label   text,
  target_phone_digits    text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id      uuid;
  v_contato uuid;
  v_fone    text;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  if not exists (
    select 1 from app.data_authorizations a
     where a.tenant_id = target_tenant_id
       and a.scope = 'HISTORICO_WHATSAPP' and a.revoked_at is null
  ) then
    return jsonb_build_object('ok', false, 'reason', 'SEM_AUTORIZACAO_REGISTRADA');
  end if;

  -- O caminho tem que começar pela pasta do próprio salão. A rota de upload já
  -- monta assim; conferir de novo aqui é o que impede um caminho forjado
  -- apontar para o arquivo de outro negócio.
  if target_storage_path not like target_tenant_id::text || '/%' then
    return jsonb_build_object('ok', false, 'reason', 'CAMINHO_FORA_DA_PASTA_DO_SALAO');
  end if;

  v_fone := nullif(regexp_replace(coalesce(target_phone_digits, ''), '[^0-9]', '', 'g'), '');

  -- Amarra ao contato do CRM pelos últimos 8 dígitos: DDD e o nono dígito
  -- variam de como cada um salvou o número, e o final não varia.
  if v_fone is not null then
    select c.contact_id into v_contato
      from app.crm_contact_channels c
     where c.tenant_id = target_tenant_id
       and right(regexp_replace(c.address_normalized, '[^0-9]', '', 'g'), 8) = right(v_fone, 8)
     limit 1;
  end if;

  -- Sem telefone, tenta pelo nome exato. É pista fraca, então só vale quando
  -- houver exatamente UM contato com aquele nome: dois "Andreia" não podem
  -- virar um chute.
  if v_contato is null and coalesce(trim(target_contact_label), '') <> '' then
    select c.id into v_contato
      from app.crm_contacts c
     where c.tenant_id = target_tenant_id
       and lower(trim(c.display_name)) = lower(trim(target_contact_label))
     having count(*) = 1;
  end if;

  insert into app.wa_archives
    (tenant_id, contact_id, contact_label, phone_digits,
     source_filename, storage_path, imported_by)
  values
    (target_tenant_id, v_contato, trim(target_contact_label), v_fone,
     target_filename, target_storage_path, target_email)
  on conflict (tenant_id, storage_path) do update
    set contact_label = excluded.contact_label,
        updated_at = statement_timestamp()
  returning id into v_id;

  return jsonb_build_object(
    'ok', true, 'archiveId', v_id,
    'contactId', v_contato,
    'amarrado', v_contato is not null);
end;
$function$;

grant execute on function public.site_wa_archive_add(text, text, uuid, text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Apagar os dados de uma cliente alcança o histórico importado
-- ---------------------------------------------------------------------------
--
-- Devolve os caminhos do balde para quem chamou apagar os arquivos. O banco
-- não alcança o Storage, e registro sem arquivo é exatamente a foto que
-- continua existindo depois de a pessoa pedir para sumir.

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

  -- Os caminhos são colhidos ANTES de apagar: depois do delete não há mais de
  -- onde tirar essa informação.
  select coalesce(array_agg(caminho), '{}') into v_caminhos
    from (
      select a.storage_path as caminho
        from app.wa_archives a
       where a.tenant_id = target_tenant_id and a.contact_id = target_contact_id
      union all
      select m.storage_path
        from app.wa_archive_media m
        join app.wa_archives a on a.id = m.archive_id
       where a.tenant_id = target_tenant_id and a.contact_id = target_contact_id
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
