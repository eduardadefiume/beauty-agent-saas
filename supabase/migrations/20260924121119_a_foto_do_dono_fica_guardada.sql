-- A FOTO DO DONO FICA GUARDADA.
--
-- 24/09/2026, 11:10. A dona mandou uma colagem de ruivos e escreveu "isso aqui
-- sao tons de ruivo". O Eddy respondeu "anotado que essa colagem e referencia
-- de Ruivo" -- e gravou so a frase. A imagem foi descartada pelo leitor de
-- midia, e app.tone_family_photos continua com zero linhas em todos os saloes.
-- A atendente compara a foto da cliente com uma regua sem foto nenhuma.
--
-- O leitor descarta de proposito: foto de CLIENTE e dado pessoal, e o que se
-- guarda e a leitura. Foto do DONO e outra coisa -- e aula e e portfolio. Ela
-- passa a ficar no bucket `conhecimento`, na pasta do salao, e ganha uma linha
-- aqui ate o Eddy decidir para onde ela vai.
--
-- `destino` nulo = foto que o dono mandou e ninguem classificou ainda. E essa
-- lista que o Eddy recebe para ligar "essas 6 sao ruivo" as seis fotos certas.

create table if not exists app.midias_do_dono (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references app.tenants(id) on delete cascade,
  conversation_id  uuid not null,
  message_id       uuid not null unique references app.crm_messages(id) on delete cascade,
  storage_path     text,
  mime             text,
  assunto          text check (assunto in ('TOM', 'CORTE', 'TOM_E_CORTE', 'TECNICA', 'TABELA_OU_ARTE', 'OUTRO')),
  certeza          numeric(3, 2) check (certeza is null or (certeza >= 0 and certeza <= 1)),
  leitura          text,
  destino          text check (destino in ('FAMILIA_DE_TOM', 'OPCAO_DA_REGUA', 'REGRA', 'CONHECIMENTO', 'PORTFOLIO', 'DESCARTADA')),
  destino_id       uuid,
  destinado_em     timestamptz,
  created_at       timestamptz not null default statement_timestamp()
);

alter table app.midias_do_dono enable row level security;

create index if not exists midias_do_dono_sem_destino_idx
  on app.midias_do_dono (conversation_id, created_at)
  where destino is null;

comment on table app.midias_do_dono is
  'Foto que o dono mandou ao Eddy. O arquivo fica no bucket conhecimento, na pasta do salao. destino nulo = ainda nao classificada; e a lista que o Eddy liga a legenda que vem depois.';

create or replace function app.registrar_midia_do_dono(
  p_message_id   uuid,
  p_storage_path text,
  p_mime         text,
  p_assunto      text,
  p_certeza      numeric,
  p_leitura      text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_msg record;
  v_id  uuid;
begin
  select m.tenant_id, m.conversation_id into v_msg
    from app.crm_messages m
   where m.id = p_message_id;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'MENSAGEM_NAO_EXISTE');
  end if;

  if not app.conversa_e_do_dono(v_msg.conversation_id) then
    return jsonb_build_object('ok', false, 'reason', 'NAO_E_DO_DONO');
  end if;

  insert into app.midias_do_dono
    (tenant_id, conversation_id, message_id, storage_path, mime, assunto, certeza, leitura)
  values
    (v_msg.tenant_id, v_msg.conversation_id, p_message_id, p_storage_path, p_mime,
     case when p_assunto in ('TOM', 'CORTE', 'TOM_E_CORTE', 'TECNICA', 'TABELA_OU_ARTE', 'OUTRO')
          then p_assunto else 'OUTRO' end,
     case when p_certeza between 0 and 1 then round(p_certeza, 2) end,
     left(p_leitura, 4000))
  on conflict (message_id) do update
    set storage_path = coalesce(excluded.storage_path, app.midias_do_dono.storage_path),
        mime         = coalesce(excluded.mime, app.midias_do_dono.mime),
        assunto      = excluded.assunto,
        certeza      = excluded.certeza,
        leitura      = excluded.leitura
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$fn$;

revoke all on function app.registrar_midia_do_dono(uuid, text, text, text, numeric, text) from public, anon, authenticated;

create or replace function public.registrar_midia_do_dono(
  p_message_id uuid, p_storage_path text, p_mime text,
  p_assunto text, p_certeza numeric, p_leitura text
) returns jsonb language sql security definer set search_path to ''
as $$ select app.registrar_midia_do_dono(p_message_id, p_storage_path, p_mime, p_assunto, p_certeza, p_leitura); $$;

revoke all on function public.registrar_midia_do_dono(uuid, text, text, text, numeric, text) from public, anon, authenticated;
grant execute on function public.registrar_midia_do_dono(uuid, text, text, text, numeric, text) to service_role;
