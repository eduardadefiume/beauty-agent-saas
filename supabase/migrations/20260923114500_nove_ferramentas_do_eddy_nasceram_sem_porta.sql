-- NOVE FERRAMENTAS DO EDDY NASCERAM SEM PORTA, E DUAS DELAS FAZ DOIS DIAS.
--
-- 23/09/2026. A Edge Function chama o banco por PostgREST, e o PostgREST so
-- enxerga o schema `public`. Funcao que mora so em `app` nao e "protegida":
-- ela e INALCANCAVEL. O `rpc()` leva 404, a excecao sobe, e la em cima ha um
-- `catch` que nao reclama. O agente entao improvisa uma frase simpatica.
--
-- COMO ISSO APARECEU. Primeira conversa real num salao zerado:
--
--   dona:  "Eduarda Defiume Beauty. Rua Rui Barbosa, 323"
--   Eddy:  "Anotei o nome: Eduarda Defiume Beauty."
--   banco: units.name = "Unidade unica"   <- nada foi gravado
--
--   dona:  "Eu dona, a Karen ... e a Duda que vem a cada 15 dias"
--   Eddy:  "Isso aqui eu nao consigo fazer por aqui. Ja avisei a Eduarda."
--   banco: agent_alerts = 0 linhas        <- ninguem foi avisado
--
-- O QUE ISSO EXPLICA PARA TRAS, e o que mais dói:
--
--   `onboarding_definir_preco`       nasceu em 21/09 sem porta. O bug da
--                                    Coloracao a R$160, em que o Eddy disse
--                                    ter gravado tres precos e so um entrou,
--                                    foi tratado como problema de prompt
--                                    durante dois dias. Era 404.
--   `onboarding_criar_variacao`      idem. As variacoes nunca foram criadas.
--   `registrar_conhecimento_solto`   o mecanismo de APRENDER o que ele nao
--                                    entendeu. `conhecimento_nao_classificado`
--                                    tem ZERO linhas em todos os saloes, desde
--                                    que foi criado. Ele nunca aprendeu nada.
--   `registrar_pedido_fora_do_alcance` o alerta para a Eduarda.
--                                    `agent_alerts` tem ZERO linhas. Toda vez
--                                    que o Eddy disse "ja avisei a Eduarda",
--                                    era mentira -- sem ele saber.
--
-- A LICAO, e ela vale mais que o conserto: FUNCAO NOVA EM `app` NAO EXISTE
-- PARA O AGENTE ENQUANTO NAO TIVER ESPELHO EM `public`. Testar chamando
-- `app.funcao(...)` no SQL passa, e prova exatamente nada sobre o caminho que
-- o agente percorre. Foi o que eu fiz em 21/09 e hoje de manha: testei o lado
-- de dentro da porta e declarei a casa aberta.
--
-- O espelho e de uma linha, sem logica propria de proposito: duas
-- implementacoes divergem, um encaminhamento nao tem como.

create or replace function public.onboarding_registrar_identidade(
  p_tenant_id uuid, p_nome text, p_endereco text default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_registrar_identidade(p_tenant_id, p_nome, p_endereco); $$;
revoke all on function public.onboarding_registrar_identidade(uuid, text, text) from public, anon, authenticated;
grant execute on function public.onboarding_registrar_identidade(uuid, text, text) to service_role;

create or replace function public.onboarding_criar_membro_equipe(
  p_tenant_id uuid, p_nome text, p_tipo text default 'PROFESSIONAL'
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_criar_membro_equipe(p_tenant_id, p_nome, p_tipo); $$;
revoke all on function public.onboarding_criar_membro_equipe(uuid, text, text) from public, anon, authenticated;
grant execute on function public.onboarding_criar_membro_equipe(uuid, text, text) to service_role;

create or replace function public.onboarding_criar_habilidade(
  p_tenant_id uuid, p_nome text, p_quem_faz text[] default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_criar_habilidade(p_tenant_id, p_nome, p_quem_faz); $$;
revoke all on function public.onboarding_criar_habilidade(uuid, text, text[]) from public, anon, authenticated;
grant execute on function public.onboarding_criar_habilidade(uuid, text, text[]) to service_role;

create or replace function public.onboarding_definir_horario_funcionamento(
  p_tenant_id uuid, p_dias jsonb
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_definir_horario_funcionamento(p_tenant_id, p_dias); $$;
revoke all on function public.onboarding_definir_horario_funcionamento(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.onboarding_definir_horario_funcionamento(uuid, jsonb) to service_role;

-- As tres de 21/09 que nunca chegaram a rodar.

create or replace function public.onboarding_definir_preco(
  p_tenant_id uuid, p_service_id uuid, p_preco_reais numeric, p_e_piso boolean default false
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_definir_preco(p_tenant_id, p_service_id, p_preco_reais, p_e_piso); $$;
revoke all on function public.onboarding_definir_preco(uuid, uuid, numeric, boolean) from public, anon, authenticated;
grant execute on function public.onboarding_definir_preco(uuid, uuid, numeric, boolean) to service_role;

create or replace function public.onboarding_criar_variacao(
  p_tenant_id uuid, p_service_id uuid, p_nome text, p_preco_reais numeric
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_criar_variacao(p_tenant_id, p_service_id, p_nome, p_preco_reais); $$;
revoke all on function public.onboarding_criar_variacao(uuid, uuid, text, numeric) from public, anon, authenticated;
grant execute on function public.onboarding_criar_variacao(uuid, uuid, text, numeric) to service_role;

create or replace function public.onboarding_desativar_servico_por_nome(
  p_tenant_id uuid, p_nome text
) returns jsonb language sql security definer set search_path to ''
as $$ select app.onboarding_desativar_servico_por_nome(p_tenant_id, p_nome); $$;
revoke all on function public.onboarding_desativar_servico_por_nome(uuid, text) from public, anon, authenticated;
grant execute on function public.onboarding_desativar_servico_por_nome(uuid, text) to service_role;

-- E as duas que sustentam o "ele aprende": sem elas o Eddy esquece tudo que
-- nao soube fazer, e a Eduarda nunca fica sabendo que um dono pediu algo que
-- o produto nao tem.

create or replace function public.registrar_pedido_fora_do_alcance(
  p_conversation_id uuid, p_pedido_do_dono text, p_motivo_do_eddy text
) returns jsonb language sql security definer set search_path to ''
as $$ select app.registrar_pedido_fora_do_alcance(p_conversation_id, p_pedido_do_dono, p_motivo_do_eddy); $$;
revoke all on function public.registrar_pedido_fora_do_alcance(uuid, text, text) from public, anon, authenticated;
grant execute on function public.registrar_pedido_fora_do_alcance(uuid, text, text) to service_role;

create or replace function public.registrar_conhecimento_solto(
  p_tenant_id uuid, p_conversation_id uuid, p_palavras text,
  p_modulo text default null, p_escopo text default null, p_porque text default null
) returns jsonb language sql security definer set search_path to ''
as $$ select app.registrar_conhecimento_solto(p_tenant_id, p_conversation_id, p_palavras, p_modulo, p_escopo, p_porque); $$;
revoke all on function public.registrar_conhecimento_solto(uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.registrar_conhecimento_solto(uuid, uuid, text, text, text, text) to service_role;
