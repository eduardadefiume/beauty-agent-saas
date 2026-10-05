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

## Aviso de falha (05/10/2026)

- `app.operator_contacts` (Duda, 5516994215487) recebe no WhatsApp os alertas de `app.agent_alerts`
  (cron `avisar-operadora`, 1/min). Conversa da operadora num salão que não é dela nasce pausada.
- Crédito/chave/IA ocupada não estacionam mais conversa (8 em 8 min); 1ª resposta boa libera todas.
- Modelo `alerta_da_operacao` enviado à Meta em 05/10 (PENDING). Sem ele, cai no `aviso_ao_dono`.

## Como trabalhar

- Responder à Duda **sempre em português**, curto, passo a passo, com honestidade brutal.
- Antes de dizer "funciona", testar e mostrar a prova (o que ficou gravado no banco).
- **REGRA DA DUDA (30/09/2026): ESGOTAR TODAS AS POSSIBILIDADES ANTES DE QUALQUER RESPOSTA.**
  Antes de responder e na hora de testar: pensar em todas as lacunas (caminho feliz, erro,
  borda, concorrência, repetição, cliente real falando do jeito dela, dono mexendo por fora,
  conexão que cai) e testar cada uma do jeito que o dono/cliente faria de verdade, ponta a
  ponta (WhatsApp → banco → Google). Só dizer "testado" com todas testadas e a prova de cada uma.
  Achou falha: corrigir, retestar e só então seguir. Nada de teste raso nem de "deve funcionar".
- **REFORÇO DA DUDA (01/10/2026): ESGOTAR TODAS AS POSSIBILIDADES SEMPRE, EM TODO TESTE**, para o
  erro não se repetir e para prever o problema antes de ele acontecer. Método obrigatório:
  1. Antes de mexer, escrever a **matriz de casos** do que vai mudar: cada jeito real de a
     cliente/dono dizer a mesma coisa (gíria, erro de digitação, tudo numa frase, em partes,
     áudio, foto errada, mudou de ideia, voltou depois, respondeu outra coisa), cada borda
     (data, hora, mês, valor, vazio, repetido, duas pessoas ao mesmo tempo) e cada falha
     (conexão, prazo vencido, ferramenta que recusa).
  2. Toda regra que o código aplica ganha **teste automático com todos os casos da matriz**
     (vitest em `apps/web/app/*.test.ts`) — e o teste tem que falhar sem o conserto.
  3. Toda função de banco nova: rodar **todos os casos** da matriz numa consulta e conferir.
  4. Ao vivo pelo WhatsApp simulado: no mínimo o caminho feliz + os 3 casos mais prováveis de
     dar errado + o caso que já deu errado antes. Prova = o que ficou gravado (banco/Google).
  5. Todo deslize de conversa visto (mesmo pequeno) entra na lista e é corrigido com teste,
     não "anotado para depois".
  6. Depois de cada conserto, procurar o **mesmo tipo de erro em outros lugares** do produto.
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
