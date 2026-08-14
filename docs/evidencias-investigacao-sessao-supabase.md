# Evidências — sessão administrativa Supabase

## Registro inicial

Em 13 de agosto de 2026, a sessão do navegador foi restabelecida pela proprietária após uma navegação entre o servidor temporário de transferência de SQL e o SQL Editor do projeto DEV. O editor voltou a listar o projeto `hjghwryhphgusefyivbl` e a função de execução SQL.

| Evidência | Estado | Implicação |
|---|---|---|
| Projeto DEV acessível no SQL Editor após novo login | Confirmado | As credenciais e as permissões administrativas permanecem válidas. |
| Sessão perdida após redirecionamento externo para o SQL Editor | Observado | A execução por redirecionamento de navegador é frágil e não deve ser o caminho operacional recorrente. |
| Teste de endpoint administrativo direto | Não disponível neste contexto | A sessão do painel está protegida fora do `localStorage`; não há token administrativo exposto para chamada direta. |

## Hipótese operacional

O problema observado é consistente com uma sessão de painel dependente de cookies e de redirecionamento entre origens. Para a operação atual, o SQL será carregado no editor já autenticado por uma requisição CORS ao servidor de transferência, sem sair de `supabase.com`. Isso elimina o redirecionamento que precipitou o novo login.

Para migrações recorrentes, a solução definitiva não é manter um navegador aberto: é usar uma credencial administrativa de deploy, guardada fora do repositório e rotacionável, por meio da CLI ou de um pipeline de CI. Essa credencial ainda não foi provisionada para este projeto, portanto não será improvisada nem salva em código.

## Limite de evidência — validação do catálogo técnico

Em 13 de agosto de 2026, a consulta pós-migração preparada para inspecionar tabelas, RLS, colunas, restrição de duração, trigger de draft e conteúdo do snapshot falhou no cliente do SQL Editor com a mensagem `query: Too small: expected string to have >=1 characters`. A falha ocorreu antes de uma resposta do PostgreSQL.

Consequentemente, o resultado **não valida** schema, RLS, constraint nem trigger. Há somente o retorno de sucesso da transação de migração. A entrega permanece pendente de inspeção independente por canal de leitura confiável.

## Padrão de status obrigatório

| Status | Evidência mínima exigida | Não significa |
|---|---|---|
| Executado | Retorno explícito do mecanismo de execução | Schema, segurança ou comportamento validados |
| Verificado por consulta | Resultado armazenado de consulta independente e somente de leitura | Fluxo de aplicação testado |
| Testado | Caso automatizado ou manual reproduzível com resultado registrado | Liberação para produção |
| Bloqueado | Impedimento e ausência de dado necessário registrados | Falha definitiva do componente |

Nenhum status acima pode ser inferido a partir de intenção, código local ou resposta parcial da interface.

## Inventário do canal reprodutível

| Item verificado | Resultado observável | Consequência |
|---|---|---|
| CLI Supabase no ambiente de trabalho | Não instalada | Não há execução versionada disponível neste ambiente por padrão. |
| Endpoint REST do projeto DEV para o schema `app` | Rejeitou leitura com `PGRST106`: somente `public` e `graphql_public` são expostos | A proteção de schema privado impede usar PostgREST como auditoria do catálogo. |
| Tokens de acesso na conta Supabase | Dois tokens existentes, ambos mascarados pela interface; um deles usado há oito dias | A interface não revela o valor de token existente. É necessário criar um token dedicado, com expiração, para a CLI/pipeline de validação. |

Em seguida, a proprietária informou que não recebeu nenhum valor para cópia. Portanto, não há token novo comprovadamente criado e nenhum valor secreto foi recebido ou usado nesta tarefa.

Posteriormente, a tela de tokens confirmou a criação de `beauty-agent-ci`, com validade até 12 de setembro de 2026, e exibiu seu valor uma única vez em aviso de sucesso. A proprietária confirmou a cópia. O cofre de Actions do repositório `eduardadefiume/beauty-agent-saas` estava sem segredos e o formulário de novo segredo foi aberto; nenhum segredo foi salvo ainda.

Na sequência, a proprietária informou que criou e copiou um token substituto. A tela de segredos do repositório confirmou o aviso `Repository secret added` e a existência do segredo de repositório `SUPABASE_ACCESS_TOKEN`. O valor não foi exibido nem acessado após a gravação.

## Referência de automação reproduzível

A documentação oficial do Supabase especifica que a CLI pode executar de modo não interativo com `SUPABASE_ACCESS_TOKEN`, que esse segredo deve ser armazenado como segredo criptografado no GitHub Actions e que o fluxo de banco remoto usa `supabase link --project-ref` seguido de `supabase db push`. Ela também deixa claro que operações que validam ou acessam o banco remoto exigem a senha do banco quando aplicável. Portanto, o token de acesso por si só não substitui a credencial de banco para consultas SQL arbitrárias. [Supabase — Managing Environments](https://supabase.com/docs/guides/deployment/managing-environments) e [Supabase CLI Reference](https://supabase.com/docs/reference/cli/introduction).

A referência atual da Management API documenta `POST /v1/projects/{ref}/database/query`, aceita `query` e `read_only`, exige token Bearer e prevê `database_read` ou `database_write` para token de granularidade fina. Esse endpoint permite a verificação estrutural sem senha de banco e sem acesso pelo SQL Editor. [Supabase — Run SQL Query](https://supabase.com/docs/reference/api/v1-run-a-query) e [Supabase — Management API](https://supabase.com/docs/reference/api/introduction).

## Bloqueio de publicação no GitHub

Em 13 de agosto de 2026, a conta `eduardadefiume` foi autenticada novamente no GitHub CLI e a API confirmou `permissions.push = true` para o repositório. Apesar disso, a tentativa de escrita via Git e a publicação por API retornaram HTTP 403, sendo esta última com `Resource not accessible by integration`. Portanto, a credencial de integração atualmente disponível não pode publicar o commit. O token pessoal recém-criado não foi recebido em conversa nem aplicado localmente; sua aplicação precisa ocorrer por um canal efêmero sem registro em código, logs ou histórico.

O teste posterior com token pessoal retornou HTTP 403 com a mensagem `Resource not accessible by personal access token`. Isso comprova que a credencial não possui todos os acessos necessários à publicação prevista. O valor do token não é registrado neste documento e deve ser revogado antes de uma nova tentativa, pois foi inserido em uma página de teste que não é parte do cofre GitHub.

Inspeção posterior do ambiente local confirmou que a branch ativa é `feature/saas-com-dashboard-completo`, que o commit local pendente é `41c44ff` e que a referência remota ainda está em `479fd6a`. Não há helper de credenciais nem regra de reescrita de URL configurados localmente. A própria CLI reporta um token de integração com prefixo `ghu_`; portanto, a reautorização por dispositivo não substituiu a credencial que o transporte Git usa. Esta é a causa observável da persistência do `403` no transporte Git.

A documentação oficial do GitHub informa que tokens pessoais de granularidade fina dependem de permissões específicas por recurso e que a resposta de API pode indicar os acessos requeridos pelo cabeçalho `X-Accepted-GitHub-Permissions`. A publicação de arquivos dentro de `.github/workflows` precisa da autorização adicional correspondente ao domínio de Actions/Workflows, além do acesso de conteúdo. Referência: [GitHub — Permissions required for fine-grained personal access tokens](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).

A referência do endpoint de conteúdo declara explicitamente que o escopo `workflow` também é exigido para modificar arquivos no diretório `.github/workflows`. A documentação de tokens confirma que PATs podem autenticar Git e API, mas recomenda a alternativa mais restrita que atenda ao caso. Referências: [GitHub — Repository contents](https://docs.github.com/rest/repos/contents) e [GitHub — Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).

Como alternativa ao transporte Git bloqueado, a proprietária autorizou a publicação pela interface web autenticada. A auditoria posterior por hash de blob confirmou conteúdo idêntico, na branch `feature/saas-com-dashboard-completo`, para seis artefatos: `docs/auditoria-g0-g1-catalogo.md`, `.github/workflows/verify-technical-catalog.yml`, `apps/web/app/configurator-real.tsx`, `scripts/verify-technical-catalog.mjs` e `supabase/migrations/20260813190000_technical_service_catalog.sql`, além da versão então publicada deste documento.

Na mesma auditoria, `docs/evidencias-investigacao-sessao-supabase.md` e `todo.md` estavam diferentes da cópia local porque receberam registros posteriores àquelas publicações. Esses dois arquivos permanecem pendentes de nova publicação; nenhum outro artefato do conjunto auditado está pendente.
