-- Quem é o dono dentro do arquivo, o dono é que diz.
--
-- O leitor deduzia por contagem: quem mais fala no arquivo é o dono. O teste do
-- parser mostrou o furo na hora -- numa conversa real o dono e a cliente falam
-- quase o mesmo tanto, e empate é comum. No empate o leitor não chuta (fica
-- tudo como CLIENTE, de propósito), mas aí o arquivo inteiro perde a marca de
-- quem é quem, que é justamente o que se quer aprender.
--
-- A resposta certa não é uma heurística melhor: é uma pergunta com resposta
-- certa. O dono sabe como o nome dele aparece nas conversas dele. Ele responde
-- uma vez, e vale para os cinquenta arquivos.
--
-- A dedução por contagem continua existindo como rede: quem não respondeu
-- ainda tem o arquivo lido assim mesmo, e quem empatou fica sem a marca em vez
-- de ficar com a marca trocada.

alter table app.data_authorizations
  add column if not exists owner_label text;

comment on column app.data_authorizations.owner_label is
  'Como o nome do dono aparece dentro do export do WhatsApp. Ele responde uma vez; sem isso o leitor deduz por contagem e empata em conversa equilibrada.';

create or replace function app.wa_archive_claim(p_limit integer default 3)
returns table (
  archive_id    uuid,
  tenant_id     uuid,
  storage_path  text,
  filename      text,
  contact_label text,
  owner_label   text
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
  ),
  marcados as (
    update app.wa_archives a
       set status = 'LENDO',
           read_attempts = a.read_attempts + 1,
           updated_at = statement_timestamp()
      from escolhidos e
     where a.id = e.id
    returning a.id, a.tenant_id, a.storage_path, a.source_filename, a.contact_label
  )
  select m.id, m.tenant_id, m.storage_path, m.source_filename, m.contact_label,
         (select d.owner_label from app.data_authorizations d
           where d.tenant_id = m.tenant_id and d.scope = 'HISTORICO_WHATSAPP')
    from marcados m;
end;
$function$;

revoke all on function app.wa_archive_claim(integer) from public, anon, authenticated;
grant execute on function app.wa_archive_claim(integer) to service_role;

create or replace function public.site_wa_set_owner_label(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_owner_label     text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_n integer;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  update app.data_authorizations
     set owner_label = nullif(trim(coalesce(target_owner_label, '')), '')
   where tenant_id = target_tenant_id and scope = 'HISTORICO_WHATSAPP';

  -- Os arquivos que já foram lidos sem saber o nome voltam para a fila: agora
  -- dá para marcar quem é quem neles. Reler é barato; deixar cinquenta
  -- conversas com a marca errada não é.
  update app.wa_archives
     set status = 'PENDENTE', read_attempts = 0, updated_at = statement_timestamp()
   where tenant_id = target_tenant_id and status in ('PRONTO', 'FALHOU');
  get diagnostics v_n = row_count;

  -- As mensagens saem junto: a releitura grava por posição, e posição que já
  -- existe seria ignorada, deixando a marca velha no lugar.
  delete from app.wa_archive_messages m
   using app.wa_archives a
   where m.archive_id = a.id and a.tenant_id = target_tenant_id and a.status = 'PENDENTE';

  return jsonb_build_object('ok', true, 'arquivosParaReler', v_n);
end;
$function$;

grant execute on function public.site_wa_set_owner_label(text, text, uuid, text) to service_role;
