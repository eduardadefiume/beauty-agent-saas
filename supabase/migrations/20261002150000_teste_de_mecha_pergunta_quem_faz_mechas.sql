-- O TESTE DE MECHA É PERGUNTADO A QUEM FAZ MECHAS.
--
-- 02/10, DEV, William-robô configurando do zero: o sinal ficou pronto e o
-- Eddy foi direto para o cadastro básico, sem perguntar do teste de mecha.
-- teste_mecha_resumo só via um serviço chamado "Teste de mecha" na versão
-- PUBLICADA: no cadastro (rascunho) nunca aparecia, e um salão que faz luzes
-- sem cadastrar o teste como serviço nunca seria perguntado.
--
-- Agora o resumo diz também se o salão faz mechas (luzes, mechas, morena
-- iluminada, balaiagem, platinado, descoloração), olhando o rascunho mais
-- novo e a versão publicada, e o teste cadastrado no rascunho também conta.

create or replace function app.teste_mecha_resumo(p_tenant_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $function$
  with c as (select * from app.teste_mecha_config where tenant_id = p_tenant_id),
  servicos as (
    select sv ->> 'name' nome, (sv ->> 'base_price_minor')::int preco, 1 origem, v.version_number ordem
      from app.configuration_versions v
      cross join lateral jsonb_array_elements(coalesce(v.snapshot -> 'services', '[]'::jsonb)) sv
     where v.tenant_id = p_tenant_id
    union all
    select s.name, s.base_price_minor, 2, d.revision
      from app.services s
      join app.configuration_drafts d on d.id = s.configuration_draft_id
     where s.tenant_id = p_tenant_id
       and d.revision = (select max(d2.revision) from app.configuration_drafts d2 where d2.tenant_id = p_tenant_id)
  ),
  teste as (
    select nome, preco from servicos
     where translate(lower(nome), 'áàâãéêíóôõúç', 'aaaaeeiooouc') ~ 'teste de mecha'
     order by origem, ordem desc limit 1)
  select jsonb_build_object(
    'modo', coalesce((select modo from c), 'MESMO_DIA'),
    'diasAntes', (select dias_antes from c),
    'jeitoDeFalar', (select jeito_de_falar from c),
    'respondido', coalesce((select respondido from c), false),
    'servicoDoTeste', (select nome from teste),
    'valorDoTeste', (select 'R$ ' || app.agenda_reais_curto(preco) from teste where preco is not null),
    'fazMechas', exists (
      select 1 from servicos
       where translate(lower(nome), 'áàâãéêíóôõúç', 'aaaaeeiooouc')
             ~ '(luzes|mecha|morena iluminada|iluminad|balaiagem|balayage|platinad|descolor|ombre)'));
$function$;
revoke all on function app.teste_mecha_resumo(uuid) from public, anon, authenticated;
