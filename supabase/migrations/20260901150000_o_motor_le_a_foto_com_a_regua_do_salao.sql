-- O motor de análise de foto: ele classifica com a régua DAQUELE salão.
--
-- O PEDIDO DA DUDA, palavra por palavra: "quero que construa esse motor de
-- analise porque com ele vamos verificar comprimento do cabelo, os que são o
-- padrão, os mais curtos, mais finos, os volumosos, compridos e etc". E a regra
-- de como ele erra: "o caminho é classificar com confiança alta e perguntar no
-- resto".
--
-- O QUE ELE NÃO É. Não é um classificador com categorias minhas. Se eu
-- escrevesse "curto/médio/longo" aqui dentro, teria construído o motor de UM
-- salão. As categorias saem de `knowledge_dimensions`/`knowledge_options` --
-- o que o dono cadastrou na tela de Conhecimento, com as palavras dele. Um
-- studio de cílios que cadastre "curvatura" recebe o mesmo motor sem uma linha
-- de código nova.
--
-- Estas duas funções são todo o contato do worker com o banco: uma entrega a
-- régua, a outra recebe a resposta. O worker não sabe nada sobre fichas.

-- ---------------------------------------------------------------------------
-- 1. A régua que esta foto tem que responder.
--
-- DUAS COISAS QUE ELA MANDA JUNTO, e cada uma existe por causa de um erro real:
--
--   `ultimaPerguntaDoSalao` -- porque no teste da Duda a cliente mandou a foto
--   do próprio cabelo e o sistema entendeu que era a referência de cor que ela
--   queria. Foto de cabelo não diz sozinha se é "como estou" ou "como quero
--   ficar"; quem diz é o que foi perguntado antes dela. Sem essa linha o motor
--   classificaria o comprimento de uma foto do Pinterest como se fosse o
--   cabelo da cliente.
--
--   Dimensões já respondidas por PESSOA ficam de fora -- não porque o motor
--   erraria nelas, mas porque ele não pode sobrescrevê-las de qualquer jeito.
--   Mandar seria pagar tokens por uma resposta que vai ser descartada.
-- ---------------------------------------------------------------------------
create or replace function public.photo_classification_context(p_message_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_msg    record;
  v_ficha  uuid;
  v_ultima text;
begin
  select m.tenant_id, m.conversation_id, m.direction, m.occurred_at
    into v_msg
    from app.crm_messages m
   where m.id = p_message_id;
  if not found or v_msg.direction <> 'INBOUND' then
    return jsonb_build_object('ok', false, 'reason', 'MENSAGEM_INVALIDA');
  end if;

  select p.id into v_ficha
    from app.client_profiles p
    join app.crm_conversations c
      on c.tenant_id = p.tenant_id and c.contact_id = p.contact_id
   where c.id = v_msg.conversation_id and p.tenant_id = v_msg.tenant_id;
  if v_ficha is null then
    return jsonb_build_object('ok', false, 'reason', 'SEM_FICHA');
  end if;

  select m.body_text into v_ultima
    from app.crm_messages m
   where m.conversation_id = v_msg.conversation_id
     and m.direction = 'OUTBOUND'
     and coalesce(trim(m.body_text), '') <> ''
     and m.occurred_at <= v_msg.occurred_at
   order by m.occurred_at desc
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'tenantId', v_msg.tenant_id,
    'profileId', v_ficha,
    'ultimaPerguntaDoSalao', left(coalesce(v_ultima, ''), 600),
    'dimensoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', d.id,
               'nome', d.name,
               'ondeOlhar', d.what_to_look_at,
               'opcoes', (
                 select jsonb_agg(jsonb_build_object(
                          'id', o.id, 'rotulo', o.label, 'descricao', o.description
                        ) order by o.position)
                   from app.knowledge_options o
                  where o.dimension_id = d.id and o.status = 'ACTIVE'
               )
             ) order by d.position)
        from app.knowledge_dimensions d
       where d.tenant_id = v_msg.tenant_id
         and d.status = 'ACTIVE'
         and exists (select 1 from app.knowledge_options o
                      where o.dimension_id = d.id and o.status = 'ACTIVE')
         and not exists (select 1 from app.client_classifications c
                          where c.profile_id = v_ficha
                            and c.dimension_id = d.id
                            and c.source = 'PESSOA')
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.photo_classification_context(uuid) from public, anon, authenticated;
grant execute on function public.photo_classification_context(uuid) to service_role;

comment on function public.photo_classification_context(uuid) is
  'A regua daquele salao que esta foto tem que responder, mais a ultima pergunta feita na conversa -- que e o que distingue "como meu cabelo esta" de "o tom que eu quero".';

-- ---------------------------------------------------------------------------
-- 2. A resposta do motor entra na ficha.
--
-- O worker manda [{dimensionId, optionId, confidence}]. Cada uma passa pela
-- mesma porta que uma resposta digitada por gente passaria
-- (`app.set_client_classification`), e é lá que valem as três regras: opção tem
-- que ser real e do salão certo, abaixo do limite não grava, e PESSOA nunca é
-- sobrescrita.
--
-- O RETORNO DIZ O QUE ACONTECEU COM CADA UMA. Não é enfeite: "gravou 0 de 2"
-- por confiança baixa e "gravou 0 de 2" porque o modelo inventou uuid são
-- problemas opostos, e um log que não os distingue faz o próximo debug começar
-- do zero.
-- ---------------------------------------------------------------------------
create or replace function public.record_photo_classification(
  p_message_id uuid,
  p_results    jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_ctx      jsonb;
  v_tenant   uuid;
  v_ficha    uuid;
  v_item     jsonb;
  v_resposta text;
  v_saida    jsonb := '[]'::jsonb;
begin
  v_ctx := public.photo_classification_context(p_message_id);
  if not coalesce((v_ctx->>'ok')::boolean, false) then
    return v_ctx;
  end if;
  v_tenant := (v_ctx->>'tenantId')::uuid;
  v_ficha  := (v_ctx->>'profileId')::uuid;

  for v_item in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    -- uuid malformado vindo do modelo não pode derrubar a gravação das outras.
    begin
      v_resposta := app.set_client_classification(
        v_tenant, v_ficha,
        (v_item->>'dimensionId')::uuid,
        (v_item->>'optionId')::uuid,
        'AGENTE_FOTO',
        nullif(v_item->>'confidence', '')::numeric,
        p_message_id
      );
    exception when others then
      v_resposta := 'FORMATO_INVALIDO';
    end;

    v_saida := v_saida || jsonb_build_object(
      'dimensionId', v_item->>'dimensionId',
      'resultado', v_resposta
    );
  end loop;

  return jsonb_build_object('ok', true, 'profileId', v_ficha, 'resultados', v_saida);
end;
$function$;

revoke all on function public.record_photo_classification(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_photo_classification(uuid, jsonb) to service_role;

comment on function public.record_photo_classification(uuid, jsonb) is
  'Escreve na ficha o que o motor leu na foto. Toda gravacao passa por app.set_client_classification: confianca baixa nao grava, e resposta de pessoa nunca e sobrescrita.';
