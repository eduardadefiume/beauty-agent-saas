# Os dois bancos

**23/09/2026.** Até este dia existia um banco só. Ele se chamava
`agente-beleza-saas-dev-sp` e rodava **a produção inteira**: o salão do
William, o WhatsApp no ar, 69 mil registros.

| o que é      | nome no Supabase  | ref                    | região    |
| ------------ | ----------------- | ---------------------- | --------- |
| **PRODUÇÃO** | `beleza-PRODUCAO` | `hjghwryhphgusefyivbl` | sa-east-1 |
| **DEV**      | `beleza-DEV`      | `dboygmtrzgsfcmoquegp` | sa-east-1 |

## Os nomes já mentiram, e custou caro

Até a noite de **23/09/2026** os nomes estavam **invertidos**: a produção se
chamava `agente-beleza-saas-dev-sp` e o dev, `agente-beleza-saas-prod-sp`.
Adiamos o rename porque parecia cosmético.

Não era. No mesmo dia isso fez uma sessão inteira ler o nome em vez do `ref`,
concluir que o `db push` pendente era do dev quando era da **produção**, e
escrever essa inversão dentro de uma migration. A Duda também parou no meio de
uma promoção para perguntar _"está dev ou produção?"_ — com razão.

Renomear foi um clique e **não moveu dado nenhum**. O que seria caro é mover a
produção de projeto: 183 mensagens, repontar o webhook da Meta, recriar cinco
segredos de vault e redeployar sete Edge Functions. Isso continua sem valer a
pena, e por isso os `ref` são os mesmos de sempre.

**Mesmo com os nomes certos: confira o `ref`.** É ele que o CLI usa, e é o
único que não depende de ninguém ter lembrado de atualizar um rótulo.

## Sobram dois projetos pausados, e não são estes

A conta tem **quatro** projetos, não dois. Os outros dois nasceram em 04/08 e
estão `INACTIVE`:

| nome                      | ref                    | região       |
| ------------------------- | ---------------------- | ------------ |
| `agente-beleza-saas-dev`  | `mhlnhtvvleprnamxrsoi` | ca-central-1 |
| `agente-beleza-saas-prod` | `vwtqgukockqaiptdqwtt` | us-west-2    |

Estão vazios e fora do Brasil. Não apague por impulso — confira antes se algo
ainda aponta para eles (a política de privacidade já apontou para um deles, e
ficou fora do ar sem ninguém ver).

## Como trocar de alvo

```
E:\BeautyAgentSaaS\beauty-agent-saas-oficial\scripts\ambiente.cmd            onde estou?
E:\BeautyAgentSaaS\beauty-agent-saas-oficial\scripts\ambiente.cmd dev        aponta pro DEV
E:\BeautyAgentSaaS\beauty-agent-saas-oficial\scripts\ambiente.cmd producao   pede confirmação
```

**Caminho absoluto, e `.cmd` em vez de `.ps1`.** O terminal daqui abre em
`C:\Windows\System32`: caminho relativo falha com _"O sistema não pode
encontrar o caminho especificado"_, e `.ps1` colado no `cmd` também. Os dois
aconteceram em 23/09 — o segundo bem depois de o `.cmd` existir justamente
para resolver isso.

O caso perigoso não é o comando que falha. É o `db push` logo em seguida, que
roda assim mesmo — **no alvo que estava apontado antes**. Se o push para
produção disser _"Remote database is up to date"_, o alvo não trocou.

O `supabase db push` **não pergunta para onde vai**. Ele usa o que está em
`supabase/.temp/project-ref`, escrito pelo último `link` — que pode ter sido
ontem. Por isso o script existe, e continua existindo mesmo com os nomes já
corrigidos: nome certo no painel não aparece no terminal na hora do push.

**O repouso é o dev.** Depois de mexer na produção, volte com
`ambiente.cmd dev`. Assim um push distraído cai no lugar barato.

## O fluxo

```
1. escrevo a migration
2. ambiente.cmd dev       →  npx supabase db push
3. testo no dev
4. ambiente.cmd producao  →  npx supabase db push
5. ambiente.cmd dev       (volta pro repouso)
```

## O que o DEV ainda NÃO tem, e é de propósito

O dev sobe **inerte**. Isso não é falta de configuração, é proteção:

- **`app.worker_endpoints` vazio.** A URL das funções é "semeada fora do
  controle de versão" (comentário da própria migration `20260821192344`), então
  não vem nas migrations. Sem ela, `tick_worker` devolve `SEM_CONFIGURACAO` e
  **nenhum worker dispara**.
- **Vault vazio.** Faltam os cinco: `calendar_token_key`, `whatsapp_token_key`,
  `whatsapp_two_step_pin`, `worker_gateway_jwt`, `worker_trigger_token`.

**Por que isso é bom:** um dev meio configurado que consegue chamar as funções
de produção é pior que um dev desligado. Enquanto esses dois estiverem vazios,
não existe o acidente de o dev mandar mensagem para uma cliente de verdade.

Quando for ligar o dev de vez, aponte o `functions_base_url` para
`https://dboygmtrzgsfcmoquegp.supabase.co` — **nunca** para o da produção.

## O WhatsApp não existe no dev, e não tem jeito

Um número de WhatsApp só pode viver num lugar. O `16 99412-7035` está na
produção. Então **conversa de verdade se testa na produção** — ou pelo
`/onboarding` do site, que fala com o Eddy sem WhatsApp nenhum.

O dev serve para: migration, função de banco, tela, e tudo que não depende da
Meta.

## Plano free: o dev dorme

No plano gratuito o Supabase pausa um projeto depois de uma semana sem uso.
Se o dev não responder, ele está dormindo — religa em um clique no painel, ou
pela ferramenta de restaurar projeto. Não é erro.
