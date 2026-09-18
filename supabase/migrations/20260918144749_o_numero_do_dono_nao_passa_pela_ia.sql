-- O NUMERO DO DONO NAO PRECISA PASSAR PELA IA PARA VOLTAR AO BANCO.
--
-- app.onboarding_publicar recebe o telefone como parametro. Quem ia preencher
-- esse parametro era a Edge Function, lendo do contexto -- nunca o modelo. Mas
-- "nunca o modelo" e uma promessa do codigo, e promessa de codigo se quebra na
-- proxima refatoracao que alguem fizer com pressa.
--
-- O banco ja sabe de qual conversa se trata, e a conversa ja sabe de quem e o
-- numero. Entao o telefone nao precisa dar a volta por fora: esta funcao recebe
-- a conversa e resolve o resto sozinha. O que a IA fornece passa a ser so o que
-- ela tem o direito de fornecer -- as palavras que o dono escreveu.
--
-- A funcao antiga continua existindo. Ela e a porta de quem legitimamente tem o
-- numero na mao (a tela do painel, um teste), e ela e quem carrega as travas.
-- Esta aqui e so o caminho seguro para quem chega pela conversa.

create or replace function app.onboarding_publicar_pela_conversa(
  p_conversation_id uuid,
  p_confirmacao     text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_tenant  uuid;
  v_contato uuid;
  v_fone    text;
begin
  select c.tenant_id, c.contact_id
    into v_tenant, v_contato
    from app.crm_conversations c
   where c.id = p_conversation_id;

  if v_tenant is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSA_NAO_EXISTE');
  end if;

  select ch.address_normalized
    into v_fone
    from app.crm_contact_channels ch
   where ch.tenant_id = v_tenant
     and ch.contact_id = v_contato
     and ch.provider = 'WHATSAPP'
   order by ch.is_primary desc
   limit 1;

  if v_fone is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSA_SEM_WHATSAPP');
  end if;

  -- Daqui para baixo e a funcao de sempre, com todas as travas: o numero tem
  -- que estar em owner_whatsapp, o e-mail tem que ter papel de dono, a revisao
  -- tem que bater e a prontidao tem que estar limpa.
  return app.onboarding_publicar(v_tenant, v_fone, p_confirmacao);
end;
$fn$;

comment on function app.onboarding_publicar_pela_conversa(uuid, text) is
  'Publica a partir da conversa: o telefone do dono sai do banco, nao do parametro. Existe para o Eddy nunca precisar receber -- nem poder inventar -- um numero de telefone.';

revoke all on function app.onboarding_publicar_pela_conversa(uuid, text) from public, anon, authenticated;
grant execute on function app.onboarding_publicar_pela_conversa(uuid, text) to service_role;

create or replace function public.onboarding_publicar_pela_conversa(
  p_conversation_id uuid, p_confirmacao text)
returns jsonb language sql security definer set search_path to ''
as $fn$ select app.onboarding_publicar_pela_conversa(p_conversation_id, p_confirmacao); $fn$;

revoke all on function public.onboarding_publicar_pela_conversa(uuid, text) from public, anon, authenticated;
grant execute on function public.onboarding_publicar_pela_conversa(uuid, text) to service_role;

-- O mesmo raciocinio vale para o resumo e para as pendencias: a Edge Function
-- ja tem a conversa na mao, e tenant_id e coisa que ela nao deveria precisar
-- carregar de um lado para o outro.
create or replace function app.onboarding_resumo_pela_conversa(p_conversation_id uuid)
returns jsonb language plpgsql stable security definer set search_path to ''
as $fn$
declare v_tenant uuid;
begin
  select c.tenant_id into v_tenant from app.crm_conversations c where c.id = p_conversation_id;
  if v_tenant is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSA_NAO_EXISTE');
  end if;
  return app.onboarding_resumo_do_rascunho(v_tenant)
      || jsonb_build_object('pendenciasParaPublicar',
           (app.onboarding_pendencias_de_publicacao(v_tenant))->'pendencias');
end;
$fn$;

revoke all on function app.onboarding_resumo_pela_conversa(uuid) from public, anon, authenticated;
grant execute on function app.onboarding_resumo_pela_conversa(uuid) to service_role;

create or replace function public.onboarding_resumo_pela_conversa(p_conversation_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $fn$ select app.onboarding_resumo_pela_conversa(p_conversation_id); $fn$;

revoke all on function public.onboarding_resumo_pela_conversa(uuid) from public, anon, authenticated;
grant execute on function public.onboarding_resumo_pela_conversa(uuid) to service_role;

notify pgrst, 'reload schema';
