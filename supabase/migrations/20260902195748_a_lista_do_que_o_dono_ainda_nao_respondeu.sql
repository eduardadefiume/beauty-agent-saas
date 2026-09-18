-- ETAPA 5, parte 1: a lista honesta do que este salão ainda não respondeu.
--
-- POR QUE ELA VEM PRIMEIRO. O onboarding por conversa é a IA perguntando ao
-- dono o que falta. Se a lista do que falta for chute meu, a conversa inteira
-- vira teatro: o agente pergunta o que já foi respondido e não pergunta o que
-- de verdade está vazio.
--
-- Então a lista sai do banco, item por item, com a pergunta já escrita. No
-- piloto, hoje, ela tem tamanho: 52 dos 53 serviços ativos estão sem preço
-- nenhum, as 9 perguntas de cor estão sem resposta e as 6 famílias estão sem
-- foto. Nada disso e invenção minha, é `select`.
--
-- A COLUNA `origin` DA ETAPA 4 é metade desta função. Sem ela, uma opção de
-- conhecimento plantada pelo produto e uma escrita pelo dono seriam a mesma
-- linha, e o onboarding perguntaria de novo o que o dono já respondeu -- ou,
-- pior, calaria sobre o que ninguém nunca confirmou.
--
-- `chave` é estável e legível: é por ela que a resposta do dono volta a
-- encontrar o item, e é ela que aparece no registro de auditoria.

create or replace function app.onboarding_pendencies(p_tenant_id uuid)
returns table (
  modulo     text,
  chave      text,
  pergunta   text,
  contexto   text,
  prioridade integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  -- Serviço sem preço em lugar nenhum. Primeiro da fila porque é o que faz o
  -- agente parar a conversa e chamar a dona no meio do atendimento.
  select 'SERVICOS'::text,
         'SERVICO_PRECO:' || s.id::text,
         'Quanto custa ' || s.name || '?',
         'Serviço ativo no rascunho, sem preço no catálogo nem nas variações.',
         10
    from app.services s
    join app.configuration_drafts d on d.id = s.configuration_draft_id and d.status = 'DRAFT'
   where s.tenant_id = p_tenant_id
     and s.status = 'ACTIVE'
     and s.base_price_minor is null
     and not exists (
       select 1 from app.service_variations v
        where v.service_id = s.id and v.price_minor is not null
     )

  union all

  -- Pergunta de cor que o dono ainda não respondeu. A pergunta já está escrita
  -- na tabela: quem a escreveu foi o produto, na etapa 4.
  select 'COR'::text,
         'COR_RESPOSTA:' || p.key,
         p.question,
         case when p.helper is null then 'Sem resposta; o sistema está usando a sugestão ' || p.suggested_value
              else p.helper || ' Hoje o sistema usa a sugestão ' || p.suggested_value || '.' end,
         20
    from app.color_policies p
   where p.tenant_id = p_tenant_id and p.answer_value is null

  union all

  -- Família de cor sem nenhuma foto. Aqui a resposta não é texto: é foto, e a
  -- pergunta diz isso, senão o dono responde com palavra e nada acontece.
  select 'COR'::text,
         'COR_FOTO_FAMILIA:' || f.id::text,
         'Mande uma foto de um cabelo que você chama de ' || f.name || '.',
         'A família existe mas não tem foto, então o sistema não aprendeu o que este salão chama assim.',
         30
    from app.tone_families f
   where f.tenant_id = p_tenant_id and f.status = 'ACTIVE'
     and not exists (select 1 from app.tone_family_photos ph where ph.family_id = f.id)

  union all

  -- Opção de conhecimento que veio do padrão e ninguém confirmou. "Médio" é
  -- fronteira, e fronteira muda de salão para salão.
  select 'CONHECIMENTO'::text,
         'CONHECIMENTO_DESCRICAO:' || o.id::text,
         'Em ' || d.name || ', o que é ' || o.label || ' para você?',
         'A definição de hoje veio do padrão do sistema: ' || coalesce(o.description, 'sem definição'),
         40
    from app.knowledge_options o
    join app.knowledge_dimensions d on d.id = o.dimension_id
   where o.tenant_id = p_tenant_id and o.status = 'ACTIVE' and o.origin = 'PRODUTO'

  union all

  -- Assunto que o agente vai encontrar e sobre o qual não existe regra escrita.
  -- Estes são fixos porque são as perguntas que a cliente faz em todo salão e
  -- que, sem resposta, viram ASK_OWNER no meio da conversa.
  select 'REGRAS'::text,
         'REGRA:' || t.topico,
         t.pergunta,
         'Nenhuma regra escrita sobre isso. Sem ela, o agente para e te pergunta no meio do atendimento.',
         50
    from (values
      ('PAGAMENTO',   'Que formas de pagamento o salão aceita, e parcela em quantas vezes?'),
      ('CANCELAMENTO','O que acontece quando a cliente desmarca em cima da hora ou não aparece?'),
      ('ATRASO',      'Quanto tempo de atraso você ainda atende, e o que acontece depois disso?'),
      ('SINAL',       'Algum serviço exige sinal para segurar o horário? Qual e quanto?')
    ) as t(topico, pergunta)
   where not exists (
     select 1 from app.agent_policies ap
      where ap.tenant_id = p_tenant_id and ap.status = 'ACTIVE' and ap.topic::text = t.topico
   )

  order by 5, 3;
$function$;

revoke all on function app.onboarding_pendencies(uuid) from public, anon, authenticated;
grant execute on function app.onboarding_pendencies(uuid) to service_role;

comment on function app.onboarding_pendencies(uuid) is
  'O que este salão ainda não respondeu, por módulo, com a pergunta já escrita. É a pauta do onboarding por conversa.';
