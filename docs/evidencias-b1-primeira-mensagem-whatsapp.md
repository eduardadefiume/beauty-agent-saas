# B1 — primeira mensagem real de WhatsApp chegando ao banco

Status: **fechado com prova**. 19/08/2026.
Projeto Supabase: `hjghwryhphgusefyivbl` (`agente-beleza-saas-dev-sp`).

## O que estava acontecendo

A Meta nunca havia entregue um único webhook. `app.inbox_events` estava vazia
desde sempre, e `last_webhook_at` do canal era nulo.

Duas hipóteses foram levantadas e **descartadas com evidência** antes de chegar à
causa real — vale registrar as duas, porque ambas pareciam óbvias:

1. *"O webhook aponta para o projeto Supabase pausado."* Falso — a callback URL
   estava correta, apontando para o projeto DEV ativo.
2. *"O campo `messages` não está assinado."* Falso — o painel mostrava
   `messages` como **Assinado**.

Também foi descartado que o endpoint estivesse fora do ar ou sem segredo: uma
sonda feita pelo próprio banco com `pg_net`, usando um token de verificação
deliberadamente errado, recebeu **403 Forbidden** em vez de 503. Se
`WHATSAPP_VERIFY_TOKEN` ou `META_APP_SECRET` estivessem ausentes, a função teria
respondido `WHATSAPP_WEBHOOK_NOT_CONFIGURED` antes de qualquer validação.

## A causa real

Assinar o campo `messages` e inscrever o app na WABA são **duas coisas
diferentes**. O painel mostrava a primeira feita e a segunda não.

Consulta a `GET /{WABA_ID}/subscribed_apps` retornou **apenas um app inscrito**:

```
WA DevX Webhook Events 1P App  (id 2202427980234937)
```

Esse é o app de webhooks da própria Meta, criado por ela. O app do produto —
`Beauty Agent SaaS`, id `1580552073741431` — **não estava inscrito na WABA**.
A Meta entregava os eventos, mas para o app dela, não para o nosso.

Correção: `POST /{WABA_ID}/subscribed_apps` com o token do app correto →
`{"success":true}`.

## A prova

Mensagem real enviada pela proprietária do próprio celular, poucos minutos
depois. Linha única em `app.inbox_events`:

| Campo | Valor |
| --- | --- |
| `id` | `1a9d397d-7df2-48f4-8a6f-9a9c5f2baf0a` |
| `tenant` | `piloto-eduarda` |
| `provider` | `WHATSAPP` |
| `external_event_id` | `message:wamid.HBgNNTUxNjk5NDIxNTQ4NxUCABIYFjNFQjAwMDg5Q0VEQjFCOEUxMjVDNzcA` |
| `event_type` | `WHATSAPP_MESSAGE_TEXT` |
| `contact_authorized` | `true` |
| `status` | `PENDING` |
| `received_at` | `2026-08-19 17:39:22.767+00` |

Conteúdo do payload: texto **"Boa tarde"**, de `5516994215487`, para o número
`15556587049`.

Log da Edge Function no mesmo instante, confirmando origem e resultado:

```
POST | 200 | .../functions/v1/whatsapp-webhook
request.headers.user_agent  = facebookexternalua
request.cf.asOrganization   = Facebook, Inc.
request.headers.cf_connecting_ip = 173.252.107.10
execution_time_ms           = 1345
{"event":"whatsapp_webhook_persisted","knownConnection":true,
 "accepted":1,"rejected":0,"duplicates":0}
```

Ou seja: assinatura HMAC validada, conexão reconhecida, contato autorizado,
evento persistido no tenant certo. **O encanamento inteiro está provado.**

## O que ainda não acontece

`status` continua `PENDING` e `processed_at` é nulo — de propósito. O worker de
projeção de inbox (item **B2**) ainda não existe. A mensagem chega e fica
guardada; nada a lê, nada responde. Esse é o próximo item da trilha B.

## Achado colateral, e ele importa mais do que parece

`GET /{WABA_ID}/phone_numbers` devolve **um único número**:

```json
{"id":"1283951771462695","display_phone_number":"+1 555-658-7049",
 "verified_name":"Test Number","quality_rating":"GREEN",
 "platform_type":"CLOUD_API"}
```

O piloto está rodando no **número de teste** que a Meta dá de graça. Ele serviu
para provar o encanamento, e serviu bem — mas **não serve para o piloto real**,
por três motivos:

1. É um número **dos Estados Unidos**. Nenhuma cliente do William vai mandar
   mensagem para um `+1`.
2. Só conversa com **até 5 destinatários pré-cadastrados** no painel. Não é uma
   limitação que dê para contornar: é o que define um número de teste.
3. Não é da proprietária. Não pode ser divulgado, nem impresso, nem colocado no
   Instagram do salão.

Registrar um número brasileiro de verdade na WABA é **pré-requisito do piloto**,
independente de qualquer outra coisa. Enquanto isso não for feito, o sistema só
pode ser testado por até 5 pessoas escolhidas a dedo.

## Sobre a segunda mensagem que não chegou

Depois do evento das 17:39, a proprietária enviou outra mensagem. Ela **não**
chegou: às 18:30 UTC `app.inbox_events` continuava com 1 linha, e o log da
função não registrava nenhuma chamada da Meta desde 17:39:22 — nem aceita, nem
rejeitada, nem com erro. A Meta simplesmente não bateu na porta.

O que foi verificado deste lado, e está tudo certo:

- inscrição da WABA no app `Beauty Agent SaaS`: **ativa**;
- `quality_rating` do número: **GREEN**;
- função `whatsapp-webhook`: publicada, versão 10, respondeu 200 na última
  chamada.

Não há nada quebrado na nossa metade. A verificação que falta é do lado dela:
confirmar que a mensagem foi enviada **na mesma conversa** de onde veio o
"Boa tarde" — o número `+1 555-658-7049` — e que saiu com dois tiques, não com
relógio de pendente. Mensagem enviada para qualquer outro número não gera
webhook nenhum, e é exatamente o que os dados mostram.
