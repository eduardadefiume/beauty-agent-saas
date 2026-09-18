-- O sistema lê a altura de tom da foto que o dono subiu.
--
-- É a peça que faz a correção da Duda funcionar de verdade. Ele sobe a foto e
-- diz "isto é ruivo"; a altura de tom -- que a conta de clareamento precisa --
-- sai de LER a imagem, não de ele digitar. Sem este worker, a família ficaria
-- com fotos e sem faixa, e o plano de cor continuaria dependendo da semente.
--
-- A leitura é contra a escala GLOBAL (app.tone_levels), que é a régua da
-- profissão. O que o modelo faz aqui é uma pergunta só: em que altura desta
-- escala este cabelo está? Ele não decide a família -- a família já é o que o
-- dono disse ao subir a foto.

create or replace function public.list_tone_photos_awaiting_reading(p_limit integer default 5)
returns table (
  photo_id     uuid,
  tenant_id    uuid,
  family_id    uuid,
  family_name  text,
  storage_path text,
  attempts     integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  select p.id, p.tenant_id, p.family_id, f.name, p.storage_path, p.read_attempts
    from app.tone_family_photos p
    join app.tone_families f on f.id = p.family_id
   where p.estimated_level is null
     and p.read_attempts < 3
     -- Correção de gente não volta para a fila nem quando a altura é apagada.
     and coalesce(p.level_source, '') <> 'PESSOA'
   order by p.created_at
   limit greatest(least(coalesce(p_limit, 5), 20), 1);
$function$;

revoke all on function public.list_tone_photos_awaiting_reading(integer) from public, anon, authenticated;
grant execute on function public.list_tone_photos_awaiting_reading(integer) to service_role;

-- A escala inteira, para o worker montar a pergunta com as palavras certas.
create or replace function public.tone_scale()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'nivel', l.level, 'nome', l.name, 'fundo', l.underlying_pigment
         ) order by l.level), '[]'::jsonb)
    from app.tone_levels l;
$function$;

revoke all on function public.tone_scale() from public, anon, authenticated;
grant execute on function public.tone_scale() to service_role;

-- ---------------------------------------------------------------------------
-- Gravar o que a leitura disse.
--
-- NUNCA sobrescreve correção de gente, pela mesma regra da classificação da
-- foto da cliente: quem respondeu à mão respondeu olhando, e o motor não passa
-- por cima disso.
-- ---------------------------------------------------------------------------
create or replace function public.record_tone_photo_level(
  p_photo_id uuid,
  p_level    smallint default null,
  p_error    text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_source text;
begin
  select level_source into v_source from app.tone_family_photos where id = p_photo_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'FOTO_NAO_ENCONTRADA');
  end if;
  if v_source = 'PESSOA' then
    return jsonb_build_object('ok', false, 'reason', 'PESSOA_JA_RESPONDEU');
  end if;

  if p_level is not null and p_level not between 1 and 10 then
    return jsonb_build_object('ok', false, 'reason', 'ALTURA_FORA_DA_ESCALA');
  end if;

  update app.tone_family_photos
     set read_attempts = read_attempts + 1,
         estimated_level = coalesce(p_level, estimated_level),
         level_source = case when p_level is not null then 'LIDO_NA_FOTO' else level_source end,
         read_at = case when p_level is not null then statement_timestamp() else read_at end,
         read_error = p_error,
         updated_at = statement_timestamp()
   where id = p_photo_id;

  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.record_tone_photo_level(uuid, smallint, text) from public, anon, authenticated;
grant execute on function public.record_tone_photo_level(uuid, smallint, text) to service_role;

-- ---------------------------------------------------------------------------
-- O agendador precisa conhecer o worker novo.
--
-- `worker_runs` tem uma lista fechada de quem pode rodar, e ela é fechada de
-- propósito: é o que impede um tique com nome errado de virar uma corrida
-- fantasma que nunca liquida e trava o worker de verdade. Nome novo entra
-- aqui, explicitamente.
alter table app.worker_runs drop constraint if exists worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE', 'ENVIO', 'MIDIA', 'TOM']));

alter table app.worker_heartbeat drop constraint if exists worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE', 'ENVIO', 'MIDIA', 'TOM']));

-- ---------------------------------------------------------------------------
-- O worker roda sozinho.
--
-- Dois minutos, e não trinta segundos como o leitor de mídia da conversa: a
-- diferença é quem espera. Foto de cliente no meio de um atendimento trava a
-- resposta e a pessoa está olhando o celular. Foto de referência é cadastro --
-- o William sobe dez de uma vez e volta a atender. Tique raro aqui não custa
-- nada a ninguém, e tique frequente custa uma consulta por minuto para uma
-- fila que fica vazia quase o dia inteiro.
select cron.schedule('altura-de-tom-das-fotos', '*/2 * * * *', $cron$
  select app.tick_worker('TOM', 'tone-photo-reader', '{"limit": 5}'::jsonb, 120000);
$cron$);
