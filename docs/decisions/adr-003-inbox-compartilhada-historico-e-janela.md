# ADR-003 — Inbox compartilhada: histórico, janela de 24h, allowlist e testes

Data: 20/08/2026. Status: **aceito**, com um ponto aberto marcado no fim.

Contexto: a proprietária definiu que o app precisa substituir o WhatsApp
Business para o William — múltiplos atendentes, sem queda de conexão, com todo o
histórico acessível e governança. Este documento fecha as quatro perguntas que
travavam esse desenho.

---

## 1. A janela de 24 horas — o medo era maior que o fato

Eu expliquei mal antes e assustei sem necessidade. O correto:

**A janela reinicia a cada mensagem que a cliente envia.** Não é um cronômetro
de 24h por conversa; é 24h a contar da **última** mensagem dela.

O cenário que a proprietária descreveu — cliente pergunta, agente responde,
cliente tem outra dúvida, William precisa intervir — acontece **inteiramente
dentro da janela aberta**. Cada nova pergunta da cliente empurra o prazo para
frente. O William responde à vontade, texto livre, sem template, sem custo.

A janela só fecha num caso: a cliente escreve e **ninguém responde por 24 horas
seguidas**. Aí, para reabrir, é preciso um template aprovado. E no instante em
que ela responde ao template, volta tudo ao texto livre.

Implicações de produto, que são de tela e não de backend:

- mostrar o tempo restante em cada conversa;
- avisar antes de expirar, não depois;
- quando expirada, oferecer o template de reabertura em vez de deixar o campo de
  texto falhar em silêncio.

O risco real não é a regra da Meta. É o William achar que o app está quebrado
porque o app não explicou.

---

## 2. Histórico antigo — o que é impossível e o que é possível

**Impossível:** a Meta não migra conversa de aparelho para a Cloud API. Não há
endpoint de importação, e o backup do Google Drive é cifrado ponta a ponta. Quem
disser que "migra automático" está vendendo ilusão.

**Possível, e é o caminho:** o próprio WhatsApp Business exporta conversa
(Configurações → Conversas → Exportar conversa), gerando um `.txt` com todas as
mensagens datadas, mais as mídias. Construímos um **importador** que lê esses
arquivos e grava em `crm_messages` como histórico somente-leitura, na mesma
conversa do contato.

Resultado para o William: ele abre o app e o histórico está lá.

Custo honesto: a exportação é **uma conversa por vez**, na mão, no celular dele.
Para um salão com centenas de conversas, isso é trabalho. A recomendação é
priorizar — as clientes ativas dos últimos meses resolvem 90% do valor
percebido, e o resto pode entrar depois.

Marcação no modelo: mensagens importadas entram com
`metadata_minimized.origin = 'IMPORT_WHATSAPP_EXPORT'` e sem
`provider_message_id`, para nunca serem confundidas com mensagens que passaram
pela API nem colidirem com a chave de idempotência.

**Ponto de virada que precisa ser combinado com ele:** um número não pode estar
ao mesmo tempo no app do WhatsApp Business e na Cloud API. Existe um momento de
corte. A exportação tem que acontecer **antes** dele.

---

## 3. Allowlist governa resposta automática, não retenção — corrigido

Este foi o achado mais grave desta rodada.

`api.ingest_whatsapp_webhook` descartava o conteúdo da mensagem quando o
remetente não estava na allowlist: o texto era substituído por um carimbo
`CONTACT_NOT_ALLOWLISTED` e o evento nascia `REJECTED`.

O plano do piloto é liberar o agente para poucas clientes e o William atender as
demais normalmente. Com o comportamento antigo, as mensagens dessas "demais"
seriam **destruídas na chegada**. E como o número migrado não existe mais no app
do WhatsApp, elas não existiriam em lugar nenhum. Ele perderia agendamento real.

Duas responsabilidades que estavam coladas foram separadas:

| | Antes | Agora |
| --- | --- | --- |
| Mensagem de contato fora da allowlist | conteúdo descartado, evento REJECTED | **guardada integralmente**, evento PENDING |
| Significado de `contact_authorized` | "guardamos esta mensagem" | **"o agente pode responder sozinho"** |
| Quem age sobre a allowlist | o ingestor, ao gravar | **o agente, ao decidir responder** |

A projeção carrega `agentMayReply` nos metadados da mensagem, para a tela poder
sinalizar ao operador quais conversas são automáticas e quais são dele.

Verificado com evento sintético de um número fora da allowlist:
`accepted: 1, allowlisted: 0`, mensagem projetada com
`agentMayReply: false` e conversa `OPEN`.

---

## 4. Volume de dados

Não é um problema para o horizonte visível, e vale dizer com números em vez de
adjetivos.

Um salão movimentado gera algo como 50 conversas/dia × 10 mensagens = 500
mensagens/dia, ou ~180 mil/ano. Cem salões nesse ritmo dão ~18 milhões de linhas
por ano em `crm_messages`. PostgreSQL lida com isso confortavelmente; os índices
que importam já existem (`(tenant_id, conversation_id, occurred_at desc)` e
`(tenant_id, provider_message_id)`).

O que muda com a escala, na ordem em que vai importar:

1. **Retenção** — a política já definida (conteúdo 12 meses, metadados 24,
   áudio 30 dias) é o que impede o crescimento indefinido. Falta a rotina que a
   executa, e ela depende da convergência de schema.
2. **Particionamento por tempo** em `crm_messages` — só quando passar de dezenas
   de milhões. Antes disso é otimização prematura.
3. **Busca textual** — quando o William quiser procurar "aquela cliente que
   perguntou de mechas", vai precisar de índice GIN. Não é urgente, mas é o tipo
   de coisa que muda o schema, então fica registrado.

---

## 5. Como testar ponta a ponta antes do e-SIM

A pergunta era como testar o agente respondendo sem ter um segundo número. A
resposta é que **o e-SIM não é pré-requisito para testar** — ele é
pré-requisito para o piloto real, que é outra coisa.

Três camadas, da mais rápida para a mais fiel:

**Camada 1 — evento sintético, sem WhatsApp nenhum.** Chamar
`api.ingest_whatsapp_webhook` direto no banco com um payload montado à mão, como
foi feito para provar a correção da allowlist. Testa ingestão, projeção e, quando
existir, a decisão do agente. Roda em segundos e permite simular o que quiser:
cliente nova, cliente conhecida, áudio, mensagem fora da janela.

**Camada 2 — a proprietária como cliente.** Ela manda mensagem do próprio
celular para o número do sistema e **o agente responde para ela**. Isso é o
fluxo completo, de ponta a ponta, com a Meta no meio — e precisa de um número
só, o dela. Ela faz o papel da cliente; o "salão" é o sistema.

**Camada 3 — segundo número real.** O número de teste da Meta aceita até 5
destinatários cadastrados. Dá para incluir um segundo aparelho e simular duas
clientes diferentes, inclusive conversas simultâneas.

O e-SIM entra depois disso, quando o piloto sair do número `+1` da Meta para um
número brasileiro de verdade. Não bloqueia nada do que precisa ser testado agora.

**O que de fato bloqueia a Camada 2 é o envio (outbox), que ainda não existe.**
Enquanto o sistema só escuta, "o agente responde sozinho" não tem como ser
testado por nenhuma camada. É o próximo item.

---

## Ponto aberto

Quantas conversas o William vai exportar antes do corte, e quando esse corte
acontece. É decisão dele e da proprietária, não técnica — mas trava a data do
piloto, porque a exportação tem que anteceder a migração do número.
