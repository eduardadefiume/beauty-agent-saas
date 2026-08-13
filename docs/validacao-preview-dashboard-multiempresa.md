# Validação do preview — dashboard multiempresa

## Resultado inicial

Em 13/08/2026, a URL estável de preview `https://web-git-feature-saas-com-dashboard-completo-ed-digital.vercel.app/dashboard` ainda exibiu a tela legada do Piloto William. A página continha identidade fixa, telefone e controles locais de catálogo, portanto **não pode ser usada como evidência do commit `00ad8dc`**.

O painel Vercel registrou um novo deployment da branch `feature/saas-com-dashboard-completo` imediatamente após o push, mas a URL consultada ainda serviu a versão anterior. É necessário aguardar o término do deployment atual e validar o URL imutável associado ao commit novo antes de promover qualquer versão.

## Validação do deployment imutável

O deployment do commit `00ad8dc` ficou disponível em `https://web-o2dhm5fuo-ed-digital.vercel.app`. Ao requisitar diretamente `/dashboard` sem sessão autenticada, o aplicativo redirecionou para `/login` e exibiu somente o formulário de autenticação. Não houve renderização de identidade, telefone ou informações operacionais do William.

> Este resultado aprova somente o caminho crítico de acesso sem sessão. A validação do contexto autenticado permanece pendente, pois exige uma sessão de usuário válida para este domínio de preview.

## Estado de evidência

| Critério | Situação |
|---|---|
| Build local | Aprovado: lint, 18 testes, typecheck e build de produção |
| Banco DEV | Aprovado: sete tabelas CRM com RLS habilitada e forçada |
| Código na branch | Publicado no commit `00ad8dc` |
| Preview do commit `00ad8dc`, sem sessão | Aprovado: redireciona para `/login` |
| Preview do commit `00ad8dc`, com sessão autorizada | Pendente de autenticação controlada |
| Produção `eddigital.ia.br` | Não avaliada para esta alteração; continua vinculada a outra branch |

## Reprodução autenticada do defeito relatado

Na sessão autenticada do preview `00ad8dc`, o configurador carregou em `/` e apresentou o link `Operação` como `/dashboard?tenantId=`. O parâmetro foi renderizado vazio. Ao acioná-lo, o novo dashboard abriu corretamente, porém ficou no estado **“Validando seu contexto”** por não receber um tenant válido.

O modelo William legado não é servido pelo URL imutável `00ad8dc`; o defeito atual é a ausência de `tenantId` no link do configurador e/ou uma falha subsequente do resolvedor de contexto. A correção deve preservar o redirecionamento para o dashboard genérico e eliminar a dependência de um identificador vazio.

## Causa confirmada no ambiente Preview

No projeto Vercel `web`, as variáveis públicas do Supabase estão configuradas para **Production e Preview**. Porém, `SUPABASE_CONFIGURATOR_URL` — endpoint do gateway `owner-console-api` que lista os workspaces autorizados — está configurada somente para **Production**. Por isso o configurador no preview devolve `CONFIGURATOR_NOT_AVAILABLE`, deixa `tenantId` vazio e o dashboard não consegue resolver o contexto.

O menu de edição da variável foi aberto no painel Vercel. A ação pendente é incluir **Preview** no escopo dessa mesma variável, sem alterar seu valor.

No formulário de edição, os ambientes **Production and Preview** foram selecionados, preservando Produção e incluindo Preview. O formulário permaneceu aberto após o acionamento de salvar; portanto, a persistência ainda será confirmada pela listagem de variáveis antes de um novo deployment.

A persistência foi confirmada: `SUPABASE_CONFIGURATOR_URL` aparece como **Production and Preview**, atualizada no momento da alteração. O diálogo de redeploy manual foi aberto somente para aplicar a nova configuração; porém, a lista de deployments Preview disponível nele continha apenas artefatos da branch legada `feature/fv01-checkpoint-002`. O redeploy manual não será executado para evitar publicar ou reexecutar código legado. A correção será enviada pela branch multiempresa, que criará um novo Preview automaticamente com a variável já disponível.

## Revalidação local da correção

Em 13/08/2026, após adaptar a rota `/api/dashboard-context` ao gateway autorizado e remover o fallback de tenant explícito inexistente, foram aprovados no pacote `@beauty/web`:

| Verificação | Resultado |
|---|---|
| Lint | Aprovado |
| Testes unitários | 19 aprovados, incluindo 3 do resolvedor de tenant |
| Typecheck | Aprovado |
| Build de produção | Aprovado |

O aviso de compatibilidade do `pnpm` com a versão local do Node é pré-existente e não bloqueou nenhuma verificação.

## Novo Preview da correção

O commit `61aa22b` acionou automaticamente o deployment Preview imutável `https://web-7kelgqjn2-ed-digital.vercel.app`. Nas primeiras verificações, o provedor informou **Deployment is building**; portanto, nenhuma conclusão funcional foi extraída antes do término do build.

Após o build, a sessão autenticada no mesmo Preview exibiu o configurador, com o link `Operação` efetivamente presente e apontando para `/dashboard?tenantId=4b2a8e37-1716-41c4-9201-eefce890638d`. O link está visualmente pequeno, no canto superior direito, e a tela permaneceu no estado `Carregando os dados da sua empresa…`. A navegação existe, mas não é suficientemente visível para a operação diária; o próximo ajuste dará a ela destaque explícito e testará o destino.

O Preview do ajuste visual `83ac80b` está disponível em `https://web-qw65gb7a3-ed-digital.vercel.app`. Ele concluiu o build, mas exige nova autenticação por usar um domínio imutável diferente do Preview anterior.

## Validação autenticada pela proprietária

Em 13/08/2026, após autenticação no Preview `83ac80b`, a proprietária confirmou que o fluxo funcionou. O configurador exibiu a entrada para operação e a navegação para o dashboard foi concluída. Esta é uma validação manual do caminho autenticado; não equivale a promoção de produção.
