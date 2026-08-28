-- A dedução da última vez, e por que ela pode errar sem fazer mal.
--
-- A correção anterior preencheu 229 dos 553 procedimentos casando a visita com
-- a família. Sobrou a Ariana -- 17 cronogramas capilares, cadência de 7 dias,
-- confiança ALTA -- ainda sem ritmo nenhum, porque a visita dela ("Cronograma
-- 2/4 ariana -0830") é uma das 86 que vieram do histórico sem família marcada.
-- A informação existe, está escrita na descrição, e mesmo assim o agente não
-- alcança.
--
-- ENTÃO A DEDUÇÃO ANDA MAIS UM PASSO, em três degraus, do mais firme ao mais
-- frouxo:
--   1. FICHA              -- alguém preencheu. Ganha de tudo.
--   2. VISITA_DA_FAMILIA  -- a última visita daquela mesma família.
--   3. ULTIMA_VISITA      -- a última vez que ela esteve no salão, qualquer
--                            que tenha sido o motivo.
--
-- O TERCEIRO DEGRAU É UM CHUTE, E ISSO ESTÁ TUDO BEM -- por um motivo que vale
-- escrever: ele só erra para o lado seguro. A última visita dela é sempre a
-- mais recente de todas, então usá-la faz o procedimento parecer MAIS recente
-- do que provavelmente foi. O efeito de errar é o agente ficar quieto quando
-- poderia ter oferecido. Nunca o contrário: ele não vai cobrar a Ariana de um
-- cronograma que ela fez ontem.
--
-- Se o degrau fosse ao contrário -- inventar uma data antiga -- eu não faria.
-- Um agente que diz "faz três meses que você não vem" para quem veio semana
-- passada perde a cliente na primeira frase.
--
-- `lastDoneFrom` viaja junto com a data para o agente saber em que degrau ele
-- está pisando, e a regra dele é não citar data deduzida como fato para a
-- cliente.
--
-- E o cálculo sai de dentro do build_agent_context para uma função própria.
-- Este é o terceiro arquivo seguido que reescreve aquela função inteira por
-- causa de um pedaço; isso é sinal de que o pedaço quer ser outra coisa.

create or replace function app.client_procedures_for_agent(
  p_tenant_id  uuid,
  p_profile_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'family', d.family,
           'label', d.label,
           'timesDone', d.times_done,
           'lastDoneAt', d.feito_em,
           'lastDoneFrom', d.origem,
           'cadenceDays', d.cadence_days,
           'cadenceConfidence', d.cadence_confidence,
           'daysSince', case when d.feito_em is null then null
                             else (current_date - d.feito_em) end,
           -- 1.0 = está na hora dela. Acima de 1 = passou do ciclo DELA, que
           -- não é o mesmo ciclo de mais ninguém.
           'cycleRatio', case
             when d.feito_em is null or coalesce(d.cadence_days, 0) = 0 then null
             else round((current_date - d.feito_em)::numeric / d.cadence_days, 2)
           end
         ) order by d.times_done desc, d.label), '[]'::jsonb)
    from (
      select pr.family, pr.label, pr.times_done, pr.cadence_days, pr.cadence_confidence,
             coalesce(pr.last_done_at, v_familia.quando, v_qualquer.quando) as feito_em,
             case
               when pr.last_done_at   is not null then 'FICHA'
               when v_familia.quando  is not null then 'VISITA_DA_FAMILIA'
               when v_qualquer.quando is not null then 'ULTIMA_VISITA'
             end as origem
        from app.client_procedures pr
        left join lateral (
          select max(v.occurred_on) as quando
            from app.client_visits v
           where v.tenant_id = pr.tenant_id
             and v.profile_id = pr.profile_id
             and v.family = pr.family
        ) v_familia on true
        left join lateral (
          select max(v.occurred_on) as quando
            from app.client_visits v
           where v.tenant_id = pr.tenant_id
             and v.profile_id = pr.profile_id
        ) v_qualquer on true
       where pr.tenant_id = p_tenant_id
         and pr.profile_id = p_profile_id
    ) d;
$function$;

comment on function app.client_procedures_for_agent(uuid, uuid) is
  'O que a cliente costuma fazer, com cadencia e ritmo. A data da ultima vez vem da ficha; faltando, e deduzida da visita da mesma familia; faltando as duas, da ultima visita dela -- que erra sempre para o lado de parecer mais recente, e portanto so faz o agente oferecer de menos.';

revoke all on function app.client_procedures_for_agent(uuid, uuid) from public, anon, authenticated;
grant execute on function app.client_procedures_for_agent(uuid, uuid) to service_role;

-- E o contexto passa a chamar a função em vez de calcular por dentro.
create or replace function app.build_agent_context(
  p_conversation_id uuid,
  p_history_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_c record;
  v_snapshot jsonb;
  v_estavel jsonb;
  v_volatil jsonb;
  v_catalogo jsonb;
  v_artes jsonb;
  v_cliente jsonb;
  v_perfil record;
  v_janela_aberta boolean;
  v_minutos_restantes integer;
begin
  if p_history_limit is null or p_history_limit < 1 or p_history_limit > 100 then
    raise exception 'p_history_limit deve estar entre 1 e 100, recebido %', p_history_limit;
  end if;

  select c.id, c.tenant_id, c.unit_id, c.contact_id, c.status,
         c.last_inbound_at, c.channel_connection_id,
         ch.address_normalized, ct.display_name,
         t.slug as tenant_slug, t.display_name as tenant_name,
         t.segment_hint
    into v_c
    from app.crm_conversations c
    join app.crm_contact_channels ch
      on ch.tenant_id = c.tenant_id and ch.contact_id = c.contact_id
     and ch.provider = 'WHATSAPP'
    join app.crm_contacts ct on ct.tenant_id = c.tenant_id and ct.id = c.contact_id
    join app.tenants t on t.id = c.tenant_id
   where c.id = p_conversation_id
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSATION_NOT_FOUND');
  end if;

  select cv.snapshot into v_snapshot
    from app.configuration_versions cv
   where cv.tenant_id = v_c.tenant_id
   order by cv.version_number desc
   limit 1;

  v_catalogo := coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s->>'id',
      'name', s->>'name',
      'description', s->>'description',
      'priceMinor', case when s->>'base_price_minor' is null then null
                         else (s->>'base_price_minor')::bigint end,
      'currency', s->>'currency',
      'durationMinutes', (
        select sum((st->>'duration_minutes')::integer)
          from jsonb_array_elements(coalesce(s->'steps', '[]'::jsonb)) st
      ),
      'requiresStrandTest', coalesce((s->>'requires_strand_test')::boolean, false)
    ) order by s->>'name')
    from jsonb_array_elements(coalesce(v_snapshot->'services', '[]'::jsonb)) s
    where coalesce(s->>'status', '') = 'ACTIVE'
  ), '[]'::jsonb);

  v_artes := coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id,
             'desde', a.first_seen_on,
             'confirmadaPorMaisDeUma', a.times_seen > 1,
             'conteudo', left(a.understanding, 900)
           ) order by a.first_seen_on desc, a.id)
      from (
        select a2.* from app.status_arts a2
         where a2.tenant_id = v_c.tenant_id
           and a2.retired_at is null
           and a2.last_seen_at > (statement_timestamp() - interval '21 days')
         order by a2.last_seen_at desc
         limit 3
      ) a
  ), '[]'::jsonb);

  v_estavel := jsonb_build_object(
    'unitId', v_c.unit_id,
    'business', jsonb_build_object(
      'name', v_c.tenant_name,
      'segment', v_c.segment_hint
    ),
    'catalog', v_catalogo,
    'statusArts', v_artes,
    'operatingHours', coalesce(v_snapshot->'operatingHours', '[]'::jsonb),
    'team', coalesce((
      select jsonb_agg(m->>'name' order by m->>'name')
      from jsonb_array_elements(coalesce(v_snapshot->'teamMembers', '[]'::jsonb)) m
      where coalesce(m->>'status', '') = 'ACTIVE'
    ), '[]'::jsonb)
  );

  if jsonb_array_length(v_catalogo) = 0 then
    v_estavel := v_estavel || jsonb_build_object('catalogWarning', 'NENHUM_SERVICO_PUBLICADO');
  end if;

  select p.* into v_perfil
    from app.client_profiles p
   where p.tenant_id = v_c.tenant_id and p.contact_id = v_c.contact_id
   limit 1;

  if not found then
    v_cliente := jsonb_build_object('isKnown', false);
  else
    v_cliente := jsonb_build_object(
      'isKnown', true,
      'profileStatus', v_perfil.status,
      'preferredName', v_perfil.preferred_name,
      'hair', jsonb_build_object(
        'length', (select k.label from app.knowledge_options k where k.id = v_perfil.length_option_id),
        'thickness', (select k.label from app.knowledge_options k where k.id = v_perfil.thickness_option_id)
      ),
      'chemistry', jsonb_build_object(
        'has', v_perfil.has_chemistry,
        'kind', v_perfil.chemistry_kind,
        'lastAt', v_perfil.chemistry_last_at,
        'formol', v_perfil.chemistry_formol
      ),
      'color', jsonb_build_object(
        'has', v_perfil.has_color,
        'lastAt', v_perfil.color_last_at,
        'toneWanted', v_perfil.tone_wanted
      ),
      'photoConsent', v_perfil.photo_consent_granted_at is not null,
      'notes', v_perfil.notes,
      'procedures', app.client_procedures_for_agent(v_c.tenant_id, v_perfil.id),
      'lastVisits', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'on', v.occurred_on,
                 'what', v.description,
                 'minutes', v.duration_minutes,
                 'amountMinor', v.amount_cents
               ) order by v.occurred_on desc)
          from (
            select * from app.client_visits v2
             where v2.tenant_id = v_c.tenant_id and v2.profile_id = v_perfil.id
             order by v2.occurred_on desc limit 3
          ) v
      ), '[]'::jsonb)
    );
  end if;

  v_janela_aberta := v_c.last_inbound_at is not null
    and v_c.last_inbound_at > (statement_timestamp() - interval '24 hours');

  v_minutos_restantes := case
    when v_c.last_inbound_at is null then 0
    else greatest(0, extract(epoch from (
      v_c.last_inbound_at + interval '24 hours' - statement_timestamp()
    ))::integer / 60)
  end;

  v_volatil := jsonb_build_object(
    'contact', jsonb_build_object(
      'displayName', v_c.display_name,
      'whatsapp', v_c.address_normalized
    ),
    'client', v_cliente,
    'serviceWindow', jsonb_build_object(
      'open', v_janela_aberta,
      'minutesRemaining', v_minutos_restantes
    ),
    'now', to_char(statement_timestamp() at time zone 'America/Sao_Paulo',
                   'YYYY-MM-DD"T"HH24:MI:SS'),
    'today', trim(to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'Day')) || ' ' ||
             to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY'),
    'history', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'direction', h.direction,
          'text', h.body_text,
          'at', h.occurred_at
        )
        || case
             when h.media_understanding is not null then
               jsonb_build_object(
                 'mediaKind', coalesce(h.media_kind, 'media'),
                 'mediaContent', h.media_understanding
               )
             when h.message_type = 'MEDIA' then
               jsonb_build_object(
                 'mediaKind', coalesce(h.media_kind, 'media'),
                 'mediaContent', null,
                 'mediaUnreadable', true
               )
             else '{}'::jsonb
           end
        || case when h.reply_context is not null
                then jsonb_build_object('respondeuAlgo', true)
                else '{}'::jsonb end
        order by h.occurred_at)
      from (
        select m.direction, m.body_text, m.occurred_at, m.message_type,
               m.media_understanding, m.reply_context,
               m.metadata_minimized->>'eventType' as media_kind
          from app.crm_messages m
         where m.tenant_id = v_c.tenant_id
           and m.conversation_id = v_c.id
           and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'
         order by m.occurred_at desc
         limit p_history_limit
      ) h
    ), '[]'::jsonb),
    'ownerAnswers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'question', q.question,
        'answer', q.answer,
        'answeredAt', q.answered_at
      ) order by q.answered_at)
      from app.agent_owner_questions q
     where q.tenant_id = v_c.tenant_id
       and q.conversation_id = v_c.id
       and q.status = 'ANSWERED'
       and q.consumed_at is null
    ), '[]'::jsonb),
    'pendingOwnerQuestion', exists (
      select 1 from app.agent_owner_questions q
       where q.tenant_id = v_c.tenant_id
         and q.conversation_id = v_c.id
         and q.status = 'PENDING'
    ),
    'agentMayReply', coalesce((
      select (m.metadata_minimized->>'agentMayReply')::boolean
        from app.crm_messages m
       where m.tenant_id = v_c.tenant_id
         and m.conversation_id = v_c.id
         and m.direction = 'INBOUND'
       order by m.occurred_at desc
       limit 1
    ), false)
  );

  return jsonb_build_object(
    'ok', true,
    'conversationId', v_c.id,
    'tenantId', v_c.tenant_id,
    'unitId', v_c.unit_id,
    'stable', v_estavel,
    'volatile', v_volatil
  );
end;
$function$;

comment on function app.build_agent_context(uuid, integer) is
  'Contexto do agente em dois blocos. Estavel (cacheavel, do salao): catalogo, horario, equipe e as artes de promocao no ar. Volatil (desta conversa): a ficha da cliente com cadencia e ritmo -- com a ultima data deduzida das visitas quando a ficha nao tiver --, o historico com leitura de imagem e audio, e a janela de 24h.';
