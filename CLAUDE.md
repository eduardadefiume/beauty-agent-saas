# Regras do projeto (definidas pela Duda, dona do produto)

## Ambientes — regra de ouro

| Branch git | Projeto Supabase                             | Para quê                                                                                                  |
| ---------- | -------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `dev`      | **beleza-DEV** (`dboygmtrzgsfcmoquegp`)      | Onde tudo é construído e TESTADO: migrações, funções, salões-robô, clientes simuladas, testes com a Duda. |
| `main`     | **beleza-PRODUCAO** (`hjghwryhphgusefyivbl`) | O que está valendo, com clientes reais. Só recebe o que já passou no DEV. Espelho do DEV.                 |
| `world`    | —                                            | Não mexer.                                                                                                |

- **Nunca testar em produção.** Inconsistência se resolve no DEV, depois sobe.
- Não criar branch nova: o trabalho vai para `dev`. Produção só via `dev → main`.
- Mudança direta em produção só em conserto urgente, e com aviso à Duda antes.
- O número de WhatsApp **+55 16 99412-7035** é da PRODUÇÃO (tem dados de clientes). No DEV
  testa-se com o WhatsApp simulado (`channel_connections.simulado`) ou com número de teste da Meta.
- Dados de clientes (conversas, fotos, telefones, fichas) **não** vão para o DEV (LGPD). Para o
  DEV vai só configuração de salão (serviços, equipe, horários, regras, régua) e dados de teste.

## Estado dos ambientes (26/09/2026)

- beleza-DEV espelhado da produção (estrutura, funções, prompts, cron) + as 15 edge functions
  publicadas + `worker_endpoints`/`worker_gateway_jwt` próprios do DEV.
- No DEV: configuração (sem cliente) de Eduarda Defiume - Beauty, Piloto Eduarda, S-William e
  Salão do William; o salão-robô Studio Rogério Hair inteiro, com canal simulado e Google falso.
- Produção limpa do robô. Fotos do robô no storage da produção ainda não foram movidas.
- **Não rodar de novo `espelhar-producao-no-dev.yml`**: ele copia a produção por cima do DEV e
  desfaz o que o DEV tem a mais (ex.: a migração 20260923235500, que a produção nunca recebeu e
  vai receber no próximo `dev → main` pelo `migrar-banco`).

## Como trabalhar

- Responder à Duda **sempre em português**, curto, passo a passo, com honestidade brutal.
- Antes de dizer "funciona", testar e mostrar a prova (o que ficou gravado no banco).
- Migração: aplicar no DEV, salvar em `supabase/migrations/<versão>_<nome>.sql` com o md5 igual ao
  aplicado. Função SECURITY DEFINER nova: `revoke ... from public, anon, authenticated` no mesmo arquivo.
- Deploy de edge function: uma função por execução do workflow e conferir o código no ar depois.

## Pendências de produto que a Duda pediu para não esquecer

- **Sinal para agendar (prioridade comercial — "é isso que vai fazer eu vender").** O dono define,
  no Eddy, o valor do sinal por procedimento. A cliente aceita o horário → vira pré-agendamento com
  prazo → recebe um link de pagamento (Pix ou cartão) com um texto educado explicando por que o sinal
  existe (se desmarcar, o salão não perde) → pagou = confirmado na agenda. Pensar antes de construir:
  quanto tempo o horário fica segurado; se outra cliente pagar o mesmo horário primeiro, quem paga
  primeiro leva e a outra recebe estorno automático ou crédito e novos horários; expiração;
  reembolso em cancelamento; provedor de pagamento e confirmação por webhook. Já existe base no
  banco (`service_deposit_policies`, `appointment_deposits`, `appointment_deposit_events`,
  workflows `g2-deposit-*`) — revisar antes de construir.
