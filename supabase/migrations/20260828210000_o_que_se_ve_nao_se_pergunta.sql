-- O que se enxerga não se pergunta, e o que se descobre se escreve.
--
-- A CONVERSA REAL, hoje, depois de o agente finalmente pedir a foto:
--   Cliente manda a foto do próprio cabelo.
--   Sistema lê: "cabelo curto, altura do queixo, tom preto/escuro, volume moderado".
--   Agente: "Perfeito, vi aqui, obrigada! Já que seu cabelo é curto, então não
--            teria correção de cor nem volume grande, né?"
--
-- A dona: "essa resposta não é para existir, ele que tem que saber que não tem
-- volume e sobre a correção de cor ele tem que pedir uma foto de como a cliente
-- gostaria do tom e não fazer essa pergunta, não se pergunta isso pra cliente".
--
-- Ela está certa em três níveis, e cada um vira uma coisa diferente aqui.
--
-- 1. TEM PERGUNTA QUE NÃO É DA CLIENTE. Volume, correção de cor, saúde do fio,
--    espessura: isso é leitura técnica de quem entende do ofício. Perguntar
--    para a cliente é pedir que ELA faça o diagnóstico, e ainda por cima em
--    forma de pergunta capciosa ("né?") que empurra a resposta. Essa regra é
--    universal e foi para o prompt do agente, não para cá.
--
-- 2. ELE JÁ SABIA E PERGUNTOU MESMO ASSIM. A leitura da foto dizia curto e
--    escuro. A ficha continuava vazia, então a lista de pendências continuava
--    mandando perguntar. O buraco é este: o agente descobre coisa na conversa
--    e não tem onde escrever. `record_client_profile_facts` é esse lugar.
--
-- 3. PEDIR DE NOVO A FOTO QUE JÁ CHEGOU. `client_profile_missing` só
--    considerava a foto existente quando alguém a tinha salvo na ficha. Mas
--    foto de conversa não é guardada de propósito, por LGPD: guardamos a
--    leitura, não a imagem. Então a marca passa a ser o carimbo de que uma foto
--    de cabelo foi vista e lida.
--
-- Nada disso é regra do William. Quais campos existem continua saindo da ficha
-- daquele negócio; um studio de cílios que não tenha comprimento no cadastro
-- simplesmente não recebe esse campo em lugar nenhum.

alter table app.client_profiles
  add column if not exists hair_photo_seen_at timestamptz;

comment on column app.client_profiles.hair_photo_seen_at is
  'Quando uma foto do cabelo desta cliente foi vista e lida numa conversa. A imagem nao e guardada (LGPD); o que fica e a leitura na mensagem e este carimbo, que evita pedir de novo a foto que ja chegou.';

-- ---------------------------------------------------------------------------
-- A leitura da foto carimba a ficha.
--
-- Vai aqui dentro, e não no worker que lê a imagem, porque quem sabe amarrar
-- mensagem -> conversa -> contato -> ficha é o banco. O worker só diz o tipo.
-- ---------------------------------------------------------------------------
create or replace function public.record_media_understanding(
  p_message_id    uuid,
  p_understanding text,
  p_error         text default null,
  p_kind          text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_msg     record;
  v_sha     text;
  v_arte_id uuid;
  v_ficha   uuid;
begin
  update app.crm_messages
     set media_attempts = media_attempts + 1,
         media_understanding = case
           when coalesce(trim(p_understanding), '') <> '' then left(p_understanding, 4000)
           else media_understanding end,
         media_understood_at = case
           when coalesce(trim(p_understanding), '') <> '' then statement_timestamp()
           else media_understood_at end,
         media_error = p_error
   where id = p_message_id
  returning tenant_id, conversation_id, direction, media_understanding, metadata_minimized
       into v_msg;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'MESSAGE_NOT_FOUND');
  end if;

  if p_kind = 'ARTE_DE_PROMOCAO'
     and v_msg.direction = 'INBOUND'
     and coalesce(trim(v_msg.media_understanding), '') <> '' then

    select e.payload #>> '{message,image,sha256}'
      into v_sha
      from app.inbox_events e
     where e.id = (v_msg.metadata_minimized->>'inboxEventId')::uuid;

    if coalesce(v_sha, '') <> '' then
      insert into app.status_arts (
        tenant_id, content_sha, understanding, sample_message_id, source
      ) values (
        v_msg.tenant_id, v_sha, v_msg.media_understanding, p_message_id, 'CLIENTE_RESPONDEU'
      )
      on conflict (tenant_id, content_sha) do update
        set times_seen   = app.status_arts.times_seen + 1,
            last_seen_at = statement_timestamp(),
            retired_at   = null
      returning id into v_arte_id;
    end if;
  end if;

  if p_kind = 'FOTO_DE_CABELO'
     and v_msg.direction = 'INBOUND'
     and coalesce(trim(v_msg.media_understanding), '') <> '' then

    update app.client_profiles p
       set hair_photo_seen_at = statement_timestamp(),
           updated_at         = statement_timestamp()
      from app.crm_conversations c
     where c.tenant_id = v_msg.tenant_id
       and c.id        = v_msg.conversation_id
       and p.tenant_id = v_msg.tenant_id
       and p.contact_id = c.contact_id
    returning p.id into v_ficha;
  end if;

  return jsonb_build_object(
    'ok', true,
    'arteRegistrada', v_arte_id,
    'fotoDeCabeloNaFicha', v_ficha
  );
end;
$function$;

grant execute on function public.record_media_understanding(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- O agente escreve na ficha o que a conversa revelou.
--
-- POR QUE RÓTULO E NÃO ID para comprimento: quem fala é um modelo lendo "meu
-- cabelo é curto". Exigir o uuid da opção seria convidar alucinação. O rótulo
-- é resolvido aqui contra as opções ATIVAS daquele negócio; se não casar com
-- nenhuma, o campo é ignorado e a função diz que ignorou, em vez de gravar
-- lixo.
--
-- NUNCA APAGA. Só preenche o que está vazio ou muda para um valor novo e
-- explícito. Um turno em que o modelo não mencione a química não pode zerar a
-- química que a cliente contou semana passada.
-- ---------------------------------------------------------------------------
create or replace function public.record_client_profile_facts(
  p_tenant_id  uuid,
  p_profile_id uuid,
  p_facts      jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_compr_txt  text := nullif(trim(coalesce(p_facts->>'comprimento', '')), '');
  v_compr_id   uuid;
  v_formol     text := upper(nullif(trim(coalesce(p_facts->>'quimicaFormol', '')), ''));
  v_ignorados  text[] := '{}';
  v_linha      app.client_profiles;
  v_falta      jsonb;
begin
  -- Vocabulario fechado no banco. Valor fora da lista e ignorado, nao gravado:
  -- constraint violada aqui derrubaria o turno inteiro do agente.
  if v_formol is not null and v_formol not in ('COM_FORMOL', 'SEM_FORMOL', 'NAO_SABE') then
    v_ignorados := v_ignorados || 'quimicaFormol';
    v_formol := null;
  end if;

  if v_compr_txt is not null then
    select o.id
      into v_compr_id
      from app.knowledge_options o
      join app.knowledge_dimensions d
        on d.id = o.dimension_id and d.tenant_id = o.tenant_id
     where o.tenant_id = p_tenant_id
       and o.status = 'ACTIVE'
       and d.status = 'ACTIVE'
       and lower(d.name) like 'compriment%'
       and lower(o.label) = lower(v_compr_txt)
     limit 1;

    if v_compr_id is null then
      v_ignorados := v_ignorados || 'comprimento';
    end if;
  end if;

  update app.client_profiles p
     set length_option_id = coalesce(v_compr_id, p.length_option_id),

         has_chemistry = coalesce((p_facts->>'temQuimica')::boolean, p.has_chemistry),
         chemistry_kind = coalesce(nullif(trim(coalesce(p_facts->>'quimicaQual','')), ''),
                                   p.chemistry_kind),
         chemistry_last_at = coalesce((nullif(p_facts->>'quimicaQuando',''))::date,
                                      p.chemistry_last_at),
         chemistry_formol = coalesce(v_formol, p.chemistry_formol),

         has_color = coalesce((p_facts->>'temColoracao')::boolean, p.has_color),
         color_last_at = coalesce((nullif(p_facts->>'coloracaoQuando',''))::date,
                                  p.color_last_at),
         tone_wanted = coalesce(nullif(trim(coalesce(p_facts->>'tomQueQuer','')), ''),
                                p.tone_wanted),

         -- A observação do agente entra somada, nunca por cima: ficha é
         -- histórico, não rascunho.
         notes = case
                   when nullif(trim(coalesce(p_facts->>'observacao','')), '') is null then p.notes
                   when p.notes is null then trim(p_facts->>'observacao')
                   else left(p.notes || E'\n' || trim(p_facts->>'observacao'), 4000)
                 end,

         updated_at = statement_timestamp()
   where p.tenant_id = p_tenant_id
     and p.id = p_profile_id
  returning * into v_linha;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'PROFILE_NOT_FOUND');
  end if;

  v_falta := app.client_profile_missing(p_tenant_id, p_profile_id);

  -- Ficha sem pendencia deixa de ser pre-cadastro. O vocabulario de status e do
  -- banco (PRE_CADASTRO, COMPLETO, ARQUIVADA); quem arquiva e uma pessoa.
  if v_falta = '[]'::jsonb and v_linha.status = 'PRE_CADASTRO' then
    update app.client_profiles
       set status = 'COMPLETO', updated_at = statement_timestamp()
     where tenant_id = p_tenant_id and id = p_profile_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'ignorados', to_jsonb(v_ignorados),
    'aindaFalta', v_falta
  );
end;
$function$;

revoke all on function public.record_client_profile_facts(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_client_profile_facts(uuid, uuid, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- A lista do que falta passa a considerar a foto que já chegou na conversa.
-- ---------------------------------------------------------------------------
create or replace function app.client_profile_missing(
  p_tenant_id  uuid,
  p_profile_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with p as (
    select * from app.client_profiles
     where tenant_id = p_tenant_id and id = p_profile_id
  ),
  tem_foto as (
    -- Duas formas de já ter a foto: alguém salvou na ficha (com consentimento),
    -- ou a cliente mandou numa conversa e o sistema leu. A segunda não guarda
    -- imagem nenhuma, só o carimbo.
    select exists (
             select 1 from app.client_photos f
              where f.tenant_id = p_tenant_id and f.profile_id = p_profile_id
                and f.kind = 'CABELO_ATUAL'
           )
           or coalesce((select hair_photo_seen_at > (statement_timestamp() - interval '120 days')
                          from p), false)
           as sim
  ),
  faltas as (
    select * from (values
      (1, 'FOTO_ATUAL',       'Manda uma foto do seu cabelo hoje, como ele está?',
          (select not coalesce(sim, false) from tem_foto)),
      (2, 'TEM_QUIMICA',      'Você já fez alguma química no cabelo?',
          (select has_chemistry is null from p)),
      (3, 'QUANDO_A_QUIMICA', 'Faz quanto tempo que você fez a última química?',
          (select coalesce(has_chemistry, false) and chemistry_last_at is null from p)),
      (4, 'QUIMICA_COM_FORMOL','Você sabe se essa química tinha formol?',
          (select coalesce(has_chemistry, false) and chemistry_formol is null from p)),
      (5, 'TEM_COLORACAO',    'Seu cabelo é colorido ou tem tintura?',
          (select has_color is null from p)),
      (6, 'QUANDO_COLORIU',   'Faz quanto tempo que você coloriu?',
          (select coalesce(has_color, false) and color_last_at is null from p)),
      (7, 'TOM_QUE_QUER',     'Me manda uma foto do tom que você quer alcançar?',
          (select tone_wanted is null from p)),
      (8, 'COMPRIMENTO',      'Seu cabelo é curto, médio ou comprido?',
          (select length_option_id is null from p))
    ) as v(ordem, campo, pergunta, falta)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'campo', campo, 'perguntaSugerida', pergunta
         ) order by ordem), '[]'::jsonb)
    from faltas where falta;
$function$;

revoke all on function app.client_profile_missing(uuid, uuid) from public, anon, authenticated;
grant execute on function app.client_profile_missing(uuid, uuid) to service_role;
