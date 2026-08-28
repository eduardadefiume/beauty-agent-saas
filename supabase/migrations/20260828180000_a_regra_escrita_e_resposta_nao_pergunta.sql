-- A regra que está escrita é resposta, não pergunta.
--
-- O ERRO, apontado pela dona olhando a decisão real do agente. Ele leu a arte,
-- viu "CABELOS LONGOS, VOLUMOSOS E COM CORREÇÃO DE COR precisam ser avaliados",
-- olhou a foto, viu cabelo longo -- e foi perguntar à dona se a cliente
-- precisava de avaliação.
--
-- A informação já estava na frente dele. Perguntar algo que está escrito na
-- própria arte é o mesmo que não ter lido. E do lado da cliente o efeito é
-- pior que ontem: ontem ele demorou porque não entendia a imagem; hoje ele
-- entendeu tudo e mesmo assim ninguém respondeu.
--
-- O que ele tinha que fazer, nas palavras da dona: conversar. Dizer que precisa
-- do teste, explicar que o teste mostra a saúde do fio, e tranquilizar --
-- morena iluminada normalmente não foge do valor da promoção.
--
-- DUAS COISAS, E A SEGUNDA É A QUE GENERALIZA.
--
-- 1. A regra de comportamento vai para o prompt, e vale para qualquer salão:
--    avaliação e teste de mecha são o CAMINHO, não obstáculo. Quando a arte ou
--    o catálogo dizem que aquele caso precisa de avaliação, isso é a resposta:
--    explique para que serve e ofereça o horário. ASK_OWNER passa a ser só
--    para o que não existe em lugar nenhum dos dados.
--
-- 2. O que é específico DESTE salão não pode virar código. "Morena iluminada
--    quase sempre fica no valor da promoção" é conhecimento do William, não
--    regra do produto -- amanhã chega um salão onde a avaliação muda o preço
--    toda vez. Então vira dado: `owner_note` na arte, escrito pelo dono,
--    entregue ao agente junto com a leitura da imagem.
--
-- Por que na arte e não numa tabela geral de conhecimento: a observação é
-- sobre AQUELA promoção. Quando a arte sai do ar, a observação sai junto, sem
-- ninguém precisar lembrar de limpar.

alter table app.status_arts
  add column if not exists owner_note text;

comment on column app.status_arts.owner_note is
  'O que o dono quer que o agente saiba sobre esta promocao especifica -- por exemplo, que a avaliacao costuma confirmar o valor anunciado. Vale mais que a leitura da imagem, porque e a pessoa falando.';

-- O dono edita a observação e aposenta a arte pela tela.
create or replace function public.site_update_status_art(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_art_id          uuid,
  target_owner_note      text default null,
  target_retired         boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_linha app.status_arts;
begin
  -- O cast importa: require_site_tenant recebe app.tenant_role[], e um literal
  -- array['OWNER','OPERATOR'] vira text[], que não casa com a assinatura.
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  update app.status_arts a
     set owner_note = case when target_owner_note is null then a.owner_note
                           else nullif(trim(target_owner_note), '') end,
         retired_at = case
                        when target_retired is null then a.retired_at
                        when target_retired then coalesce(a.retired_at, statement_timestamp())
                        else null
                      end
   where a.tenant_id = target_tenant_id and a.id = target_art_id
  returning * into v_linha;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'ART_NOT_FOUND');
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', v_linha.id,
    'ownerNote', v_linha.owner_note,
    'retired', v_linha.retired_at is not null
  );
end;
$function$;

grant execute on function public.site_update_status_art(text, text, uuid, uuid, text, boolean) to service_role;

-- Lista as artes para a tela do dono.
create or replace function public.site_load_status_arts(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER', 'OPERATOR']::app.tenant_role[]
  );

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id,
             'understanding', a.understanding,
             'ownerNote', a.owner_note,
             'timesSeen', a.times_seen,
             'firstSeenOn', a.first_seen_on,
             'lastSeenAt', a.last_seen_at,
             'source', a.source,
             'retired', a.retired_at is not null
           ) order by a.last_seen_at desc)
      from app.status_arts a
     where a.tenant_id = target_tenant_id
  ), '[]'::jsonb);
end;
$function$;

grant execute on function public.site_load_status_arts(text, text, uuid) to service_role;

-- A observação entra no contexto junto com a leitura da arte.
create or replace function app.status_arts_for_agent(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id,
           'desde', a.first_seen_on,
           'confirmadaPorMaisDeUma', a.times_seen > 1,
           'conteudo', left(a.understanding, 900),
           'ownerNote', a.owner_note
         ) order by a.first_seen_on desc, a.id), '[]'::jsonb)
    from (
      select a2.* from app.status_arts a2
       where a2.tenant_id = p_tenant_id
         and a2.retired_at is null
         and a2.last_seen_at > (statement_timestamp() - interval '21 days')
       order by a2.last_seen_at desc
       limit 3
    ) a;
$function$;

comment on function app.status_arts_for_agent(uuid) is
  'Artes de promocao no ar, para o bloco cacheado do agente. Nada que mude a toda hora entra aqui: `times_seen` viraria bytes diferentes a cada resposta de cliente e derrubaria o cache em silencio.';

revoke all on function app.status_arts_for_agent(uuid) from public, anon, authenticated;
grant execute on function app.status_arts_for_agent(uuid) to service_role;
