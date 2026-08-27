-- Anexos e áudio no caminho de saída.
--
-- Até aqui a fila de envio só carregava texto. Foto, áudio, documento e vídeo
-- são metade da conversa de um salão -- a cliente manda foto do cabelo, o
-- dono manda foto do resultado, e boa parte do que fecha venda vem em áudio.
--
-- COMO A MÍDIA VIAJA. O navegador sobe o arquivo para um balde privado do
-- Supabase; a fila guarda só o caminho. Na hora de enviar, o worker baixa do
-- balde, sobe para a Meta (que devolve um id de mídia) e manda a mensagem
-- referenciando esse id.
--
-- POR QUE NÃO MANDAR POR LINK. A Meta aceita enviar mídia por URL pública, o
-- que seria bem mais simples. Não fazemos porque isso obrigaria a tornar
-- pública a foto do cabelo de uma cliente, nem que por alguns minutos, e URL
-- que já foi pública não volta a ser privada. O balde fica fechado e quem
-- busca o arquivo é o servidor.
--
-- POR QUE `kind` E NÃO UMA TABELA NOVA. Uma mensagem de mídia é uma mensagem
-- com um arquivo pendurado, não outra coisa. Separar em tabela própria faria
-- toda leitura da conversa virar união de duas fontes, e a ordem cronológica
-- -- que é o que uma conversa é -- passaria a depender de um merge.

alter table app.outbox_messages
  add column if not exists media_storage_path text,
  add column if not exists media_mime_type    text,
  add column if not exists media_filename     text,
  -- Id devolvido pela Meta depois do upload. Guardado para não subir o mesmo
  -- arquivo duas vezes numa retentativa: upload de mídia é a parte cara e
  -- lenta do envio.
  add column if not exists media_provider_id  text;

comment on column app.outbox_messages.media_storage_path is
  'Caminho no balde privado `anexos`. O worker baixa daqui e sobe para a Meta -- o arquivo nunca fica publico.';
comment on column app.outbox_messages.media_provider_id is
  'Id da midia na Meta apos o upload. Existe para a retentativa nao subir o mesmo arquivo de novo.';

-- Balde dos anexos que saem e das mídias que entram.
--
-- Separado de `conhecimento` e de `clientes` porque tem prazo e dono
-- diferentes: foto-régua é do salão e vive enquanto a régua existir; foto de
-- ficha é da cliente e some quando ela pedir; anexo de conversa é efêmero e
-- pode ser podado por idade sem ninguém sentir falta.
--
-- 16 MB é o teto da própria Meta para mídia. Aceitar mais aqui só produziria
-- um erro depois do upload, com o arquivo já ocupando espaço.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('anexos', 'anexos', false, 16777216,
        array[
          'image/jpeg', 'image/png', 'image/webp',
          'video/mp4', 'video/3gpp',
          'audio/aac', 'audio/mp4', 'audio/mpeg', 'audio/amr', 'audio/ogg', 'audio/webm',
          'application/pdf'
        ])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists anexos_le on storage.objects;
drop policy if exists anexos_envia on storage.objects;
drop policy if exists anexos_apaga on storage.objects;

create policy anexos_le on storage.objects
  for select to authenticated
  using (bucket_id = 'anexos' and app.storage_folder_is_my_tenant(name));

create policy anexos_envia on storage.objects
  for insert to authenticated
  with check (bucket_id = 'anexos' and app.storage_folder_is_my_tenant(name));

create policy anexos_apaga on storage.objects
  for delete to authenticated
  using (bucket_id = 'anexos' and app.storage_folder_is_my_tenant(name));
