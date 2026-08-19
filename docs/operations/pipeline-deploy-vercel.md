# Pipeline de deploy da Vercel — por que o site não recebia o que era entregue

Data da investigação: 19/08/2026. Projeto Vercel `web`
(`prj_VLa7VHKjN5qgOloXTrTdFJQHkO80`), time Ed digital
(`team_7joxzF5sdGGsAWVETLfNF0SF`).

## O sintoma

A proprietária relatou três vezes, em dias diferentes, que a agenda continuava
abrindo por semana mesmo depois de a correção estar entregue e testada — "ainda
continua do mesmo jeito". A primeira hipótese foi a óbvia e estava errada em
parte: os commits estavam só na branch de trabalho
`claude/saas-beauty-salon-strategy-xx65ya`. Isso foi corrigido levando tudo para
`feature/saas-com-dashboard-completo`. O sintoma **permaneceu**.

## A causa real

`feature/saas-com-dashboard-completo` não é a Production Branch da Vercel.

Push nessa branch gera deployment de **preview**, não de produção. O que o
domínio `eddigital.ia.br` serve continuou sendo um deployment antigo.

Evidência, colhida da API da Vercel (`list_deployments`), com os campos que
importam:

| Deployment | Commit | Branch | `target` |
| --- | --- | --- | --- |
| `dpl_eHpob57oAj7y9daQSvXzywFEnutw` | `3a6e6e4` | `feature/saas-com-dashboard-completo` | **`null`** (preview) |
| `dpl_4QhnQrLkjS3fuYXPYPHtPVTyvNkz` | `81710b9` (agenda por dia) | `claude/saas-beauty-salon-strategy-xx65ya` | **`null`** (preview) |
| `dpl_5isgkQH9ih4NPBWpfXuqW9nvx5Aw` | `83ac80b` | `feature/saas-com-dashboard-completo` | **`production`** |
| `dpl_DcgpY9cBRPZNYUHPF9h1cLk3Hu6a` | `83ac80b` | `feature/saas-com-dashboard-completo` | **`production`** |

Os dois únicos deployments de produção nas últimas 20 entregas trazem
`"action": "redeploy"` e `originalDeploymentId` no metadado: foram **cliques
manuais de redeploy**, não deploy automático de push. Ambos apontam para o mesmo
commit `83ac80b`, de 14/08, autoria Manus.

Ou seja: **nada que foi entregue desde 14/08 chegou ao ar** — nem a agenda por
dia, nem a rota de login que passou a usar a chave secreta.

## A consequência que passou despercebida

Este achado explica um segundo problema que estava aberto e sem causa conhecida:
**o login por CPF está quebrado em produção**.

A sequência foi:

1. As rotas `/api/auth/login` e `/api/auth/signup` foram reescritas para chamar
   `resolve_login_email` com a chave secreta (`admin-rpc.ts`).
2. A migração F0-02 revogou `EXECUTE` de `anon` sobre `resolve_login_email`.
3. A migração foi ao banco — banco não depende da Vercel.
4. **O código não foi ao ar.**

Produção continua rodando a versão antiga, que chama a função com a chave
publicável — a chave que acabou de perder o privilégio. Quem entra por e-mail não
percebe nada; quem entra por CPF bate numa função que não pode mais executar.

A consulta de logs do Supabase no período confirmou **zero chamadas** a
`resolve_login_email`, o que também invalida a confirmação anterior de que o
caminho por CPF havia sido testado em produção: o teste que passou foi por
e-mail.

## Por que não dá para resolver por aqui

O conector MCP da Vercel expõe leitura (`list_deployments`, `get_project`,
`get_runtime_logs`) e criação de projeto novo (`deploy_to_vercel`), mas **não
expõe**:

- promoção de um deployment existente para produção;
- alteração das configurações de Git do projeto.

`deploy_to_vercel` foi descartado deliberadamente: ele sobe uma árvore de
arquivos avulsa e criaria um deployment desvinculado do Git, sem as variáveis de
ambiente e sem o *root directory* do monorepo — trocaria um problema conhecido
por um pior.

## As duas ações, na ordem

**1. Colocar no ar o que já está pronto** — resolve hoje.

Vercel → projeto `web` → **Deployments** → deployment do commit `3a6e6e4`
(`web-bkp48drq3-ed-digital.vercel.app`, `READY`) → menu `···` → **Promote to
Production**.

**2. Fazer o push voltar a publicar sozinho** — resolve para sempre.

Vercel → projeto `web` → **Settings → Git** → **Production Branch** → definir
`feature/saas-com-dashboard-completo` → Save.

A alternativa a (2) é mover a produção para `main` e passar a integrar por PR.
É a escolha mais saudável a médio prazo e resolve também E11, mas exige decisão
da proprietária: `main` está 63 commits atrás e carrega 1 commit que a branch de
trabalho não tem. Enquanto essa decisão não for tomada, (2) é o caminho de menor
risco.

## Verificação depois de promover

Duas checagens, nesta ordem — nenhuma delas é "abrir o site e achar que mudou":

1. **Agenda**: abrir o configurador e confirmar que ele abre em **Dia**, com os
   botões Dia/Semana/Mês e a faixa de horas derivada do expediente cadastrado.
2. **Login por CPF**: entrar com CPF e senha e, em seguida, confirmar nos logs
   do Supabase que houve de fato uma chamada a `resolve_login_email`. Sem essa
   segunda metade, o teste não prova nada — foi exatamente assim que o problema
   passou batido da primeira vez.

## Regra que fica

Entrega não é commit, nem push, nem migração aplicada. Enquanto o `target` do
deployment não for `production`, o que a proprietária vê é a versão anterior —
e qualquer confirmação colhida no site está falando sobre código antigo.
