# Os dois bancos, e por que os nomes mentem

**23/09/2026.** Até hoje existia um banco só. Ele se chamava
`agente-beleza-saas-dev-sp` e rodava **a produção inteira**: o salão do
William, o WhatsApp no ar, 69 mil registros.

| o que é | nome no Supabase | ref | região |
|---|---|---|---|
| **PRODUÇÃO** | `agente-beleza-saas-dev-sp` | `hjghwryhphgusefyivbl` | sa-east-1 |
| **DEV** | `agente-beleza-saas-prod-sp` | `dboygmtrzgsfcmoquegp` | sa-east-1 |

Sim, os nomes estão trocados. Foi decisão consciente em 23/09: renomear é um
clique na tela do Supabase, mas **mover a produção** de projeto significa
migrar 69 mil linhas, repontar o webhook da Meta, recriar cinco segredos de
vault e redeployar sete Edge Functions — na semana da entrega ao William.

Renomeie na tela quando sobrar uma hora calma. Até lá, **olhe o `ref`, nunca o
nome.**

## Como trocar de alvo

```powershell
.\scripts\ambiente.ps1            # onde estou?
.\scripts\ambiente.ps1 dev        # aponta pro DEV
.\scripts\ambiente.ps1 producao   # aponta pra PRODUÇÃO (pede confirmação)
```

O `supabase db push` **não pergunta para onde vai**. Ele usa o que está em
`supabase/.temp/project-ref`, escrito pelo último `link` — que pode ter sido
ontem. Por isso o script existe.

**O repouso é o dev.** Depois de mexer na produção, volte:
`.\scripts\ambiente.ps1 dev`. Assim um push distraído cai no lugar barato.

## O fluxo

```
1. escrevo a migration
2. .\scripts\ambiente.ps1 dev      →  npx supabase db push
3. testo no dev
4. .\scripts\ambiente.ps1 producao →  npx supabase db push
5. .\scripts\ambiente.ps1 dev      (volta pro repouso)
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
