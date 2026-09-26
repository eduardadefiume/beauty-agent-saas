# Casos de teste a partir do salão real do William

26/09/2026. Pedido da Duda: parar de testar o que eu acho que tem que testar e
testar o que as clientes do William de fato perguntam.

## De onde vêm os casos

| Fonte                                               | O que tem                                                                                                           | Onde está                        |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| `docs/briefing-voz-william.md`                      | Síntese medida de 551 conversas, 7.986 falas do William, 4.700 de clientes, 2.281 agendamentos, com frases literais | repositório                      |
| `client_procedures` (553) e `client_profiles` (289) | Quais procedimentos cada cliente faz, quantas vezes, cadência                                                       | produção (lido, **não copiado**) |

**Limite honesto:** a exportação crua das 551 conversas não está no banco nem
no repositório — as tabelas de importação (`wa_archives`, `wa_archive_messages`,
`wa_archive_findings`) estão vazias na produção e nos backups. Os casos abaixo
saem da síntese e dos números, não das conversas linha a linha. Se a exportação
voltar (importada na PRODUÇÃO, nunca no DEV), o `wa-archive-miner` extrai os
trechos literais e esta lista ganha a fala exata de cada cliente.

**LGPD:** nenhum nome, telefone ou foto de cliente real entra no DEV. Os casos
são reescritos por padrão; os números da produção só dão o peso de cada caso.

## Peso de cada tipo (medido no salão real)

| Tema da pergunta da cliente  | % das perguntas | Casos nesta bateria |
| ---------------------------- | --------------- | ------------------- |
| Horário / disponibilidade    | 30%             | C01–C08             |
| Preço / valor                | 18%             | C09–C15             |
| Produto / técnica e cor      | 13%             | C16–C24             |
| Pagamento                    | 2%              | C25–C26             |
| Duração / durabilidade       | 1%              | C27                 |
| Política, recorrência, borda | —               | C28–C36             |

Procedimentos mais feitos (clientes distintas): progressiva 100, corte 92,
luzes/mechas 90, selante 71, coloração 34, hidratação 33. **61 clientes (21%)
combinam alisamento e cor** — a sequência química é caso central, não de borda.

## Critérios que valem para TODO caso da atendente

Tirados das regras medidas do William. Um caso só passa se:

- **V1 Preço direto.** Pergunta de preço recebe o valor na primeira resposta ("Está 199"). Nunca "depende, vamos conversar".
- **V2 Horário concreto.** Oferece "Tenho [dia] às [hora], pode ser?". Não pergunta "que dia você prefere?" (ele faz isso 1 vez a cada 17).
- **V3 Curto.** Frases curtas, várias mensagens. Nenhuma mensagem de textão.
- **V4 Vocabulário.** Nada de "querida", "flor", "meu bem". Emoji raro.
- **V5 Sem urgência falsa.** Escassez só quando a agenda está cheia de verdade.
- **V6 Recusa com alternativa.** Todo "não tenho" vem com outra data.
- **V7 Cor sem promessa.** Não crava tom nem preço final de cor sem teste de mechas.
- **V8 Nada inventado.** Preço, horário e regra saem do cadastro/agenda. Se não tem, pergunta ao dono (ASK_OWNER) — não chuta.
- **V9 Sem raciocínio vazado.** Nada de "deixa eu ver", "hmm", "já passou...".

## Parte A — Eddy configurando o salão com o dono-robô "William"

O dono-robô fala como o William fala (curto, operacional). O Eddy passa se
**grava no banco** o que foi dito — conferido por consulta, não pela resposta.

| #   | O dono diz (padrão real)                                                 | Tem que ficar gravado                                             |
| --- | ------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| E01 | "Terça a sábado, das 9 às 19"                                            | `operating_hours` ter–sáb 09:00–19:00, dom/seg fechado            |
| E02 | "Sou eu e uma assistente, às vezes a Duda"                               | 2–3 membros na equipe, papéis certos                              |
| E03 | "Escova 70, corte 90 com escova, hidratação 120, selante 140, botox 150" | serviços com esses preços; corte com escova incluída na descrição |
| E04 | "Progressiva está 199" / "cabelo com muito volume é 450"                 | preço base + variação por volume (não um preço só)                |
| E05 | "Luzes a partir de 420, incluso hidratação e reconstrução"               | preço "a partir de" + o que inclui                                |
| E06 | "Avaliação/teste de mechas 20 reais, se passar faz no mesmo dia"         | serviço teste de mechas R$20 + regra "mesmo dia"                  |
| E07 | "Não prometo tom por mensagem, só depois do teste"                       | regra de cor ativa para a atendente                               |
| E08 | "Coloração pausa 40 min, progressiva 1h, selante 40, botox 30"           | etapas com pausa (a profissional fica livre na pausa)             |
| E09 | "Luzes umas 5h, progressiva 3h, selante 2h"                              | duração dos serviços                                              |
| E10 | "Menos de 24h não cancela nem remarca, o valor fica devido"              | política de cancelamento 24h                                      |
| E11 | "Acompanhante espera na recepção" / "interfone, digita 2"                | recado de chegada no lembrete                                     |
| E12 | "Pode lembrar um dia antes e pedir pra responder OK"                     | lembrete da véspera ligado, com pedido de confirmação             |
| E13 | Manda **áudio** com parte da tabela de preço                             | Eddy lê o áudio e grava (o erro de 25/09 foi ignorar áudio)       |
| E14 | Manda **foto** da tabela de preços                                       | Eddy lê e grava, e confirma o que entendeu                        |
| E15 | Diz algo contraditório ("botox 150"… depois "botox 120")                 | Eddy pergunta qual vale, não grava os dois                        |

## Parte B — Atendente com clientes-robô

Cada caso tem a fala da cliente (reescrita do padrão real), o que o William
faria (gabarito literal do briefing) e o critério de aprovação.

### Horário (30%)

| #   | Cliente                                         | Gabarito do William                                         | Passa se                                                          |
| --- | ----------------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------- |
| C01 | "Tem horário amanhã?"                           | "Tenho amanhã às 9:00, pode ser?"                           | Oferece 1 horário real da agenda (V2)                             |
| C02 | "Tem horário sábado?" — sábado cheio            | "Sábado os horários já esgotou, você quer uma outra data?"  | Recusa + alternativa concreta (V6)                                |
| C03 | "Queria sábado de manhã" (num sábado à tarde)   | próximo sábado                                              | Busca o próximo sábado (corrigido em 26/09)                       |
| C04 | "Só posso depois das 17h, trabalho até às 16"   | "Tenho às 18:00"                                            | Respeita a janela; não oferece antes                              |
| C05 | "Pode ser dia 12?" — dia 12 sem vaga            | "Para dia 12 não tenho horário até o momento" + alternativa | Não inventa vaga                                                  |
| C06 | "Quero marcar pra semana que vem, qualquer dia" | "Tenho na quarta às 9:00"                                   | Propõe dia+hora, não pergunta preferência                         |
| C07 | Aceita o horário: "Pode ser"                    | "Marcado"                                                   | Reserva DE VERDADE (appointment gravado) e só então diz "Marcado" |
| C08 | "Consegue me encaixar hoje?"                    | proposta ou recusa honesta                                  | Consulta a agenda de hoje; nunca horário que já passou            |

### Preço (18%)

| #   | Cliente                                                                | Gabarito                                                             | Passa se                                                          |
| --- | ---------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------- |
| C09 | "Quanto está a progressiva?"                                           | "Está 199"                                                           | Valor na 1ª resposta (V1)                                         |
| C10 | "Quanto é o corte?"                                                    | "O corte está 90 com escova"                                         | Valor + o que inclui                                              |
| C11 | "Quanto fica luzes?"                                                   | "Mechas está a partir de R$420,00 incluso hidratação e reconstrução" | "a partir de" + inclusões + explica que o final depende do cabelo |
| C12 | "Meu cabelo é bem volumoso, muda o valor?"                             | preço sobe com volume                                                | Diz que muda e por quê; dá a faixa se cadastrada; não crava       |
| C13 | "Quanto fica progressiva + corte?"                                     | soma dos dois                                                        | Soma correta ou os dois valores separados                         |
| C14 | "Faz um desconto?"                                                     | (sem política cadastrada)                                            | Não inventa desconto; ASK_OWNER ou diz que não tem                |
| C15 | "Meu cartão vira dia 10, queria saber o valor pra ver se tenho limite" | valor direto                                                         | Dá o valor; não trata como objeção                                |

### Técnica e cor (13%) — o protocolo mais importante

| #   | Cliente                                                       | Gabarito                                                | Passa se                                                                                         |
| --- | ------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| C16 | "Quero ficar loira platinada, dá?" (manda foto de referência) | "Só olhando não consigo, tem que fazer teste de mechas" | Não promete tom (V7); oferece o teste e o valor dele                                             |
| C17 | "Quantas sessões pra chegar nesse loiro?"                     | teste decide                                            | Não crava número de sessões                                                                      |
| C18 | "Faço progressiva e quero fazer luzes, pode?"                 | sequência química                                       | Pergunta o histórico/intervalo; não diz "progressiva primeiro" por conta própria (erro já visto) |
| C19 | "Tenho química, posso fazer coloração?"                       | depende do cabelo                                       | Pede foto do cabelo atual + o que quer (mínimo da química) antes de marcar                       |
| C20 | "Qual a diferença de selante e progressiva?"                  | explica curto                                           | Resposta técnica curta e correta pelo cadastro; não inventa                                      |
| C21 | "A progressiva tem formol?"                                   | pelo cadastro (há "sem formol")                         | Responde pelo cadastro; se não souber, ASK_OWNER                                                 |
| C22 | Cliente da casa: "Quero fazer minha cor de sempre"            | marca como de costume                                   | Usa o histórico; NÃO pede teste de mechas                                                        |
| C23 | Cliente da casa quer mudar o tom                              | teste de mechas + média                                 | Pede teste só porque mudou o tom                                                                 |
| C24 | Manda foto do cabelo quebrado pedindo descoloração            | não faz química                                         | Não marca química; orienta tratamento/avaliação                                                  |

### Pagamento (2%) e duração (1%)

| #   | Cliente                                             | Passa se                                                                        |
| --- | --------------------------------------------------- | ------------------------------------------------------------------------------- |
| C25 | "Aceita cartão? Parcela?"                           | Responde pela regra cadastrada (inclusive "REGRA COM CONDIÇÃO" de parcelamento) |
| C26 | "Posso pagar metade agora e metade depois?"         | Não inventa; ASK_OWNER                                                          |
| C27 | "Quanto tempo demora a progressiva? E quanto dura?" | Duração pelo cadastro (~3h); durabilidade só se cadastrada                      |

### Política, recorrência e borda

| #   | Cliente                                                                    | Passa se                                                           |
| --- | -------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| C28 | "Preciso desmarcar, é amanhã" (<24h)                                       | Aplica a política de 24h com educação; não cancela calado          |
| C29 | "Vou levar minha filha junto"                                              | Recado do acompanhante (recepção)                                  |
| C30 | Responde "OK" ao lembrete da véspera                                       | Registra a confirmação; não abre conversa nova                     |
| C31 | "Vou pra praia em novembro, quero progressiva um mês antes e hidratação"   | Planeja as datas; oferece horário no período certo                 |
| C32 | Explica a vida para justificar horário ("saio do trabalho, pego filho...") | Responde curto e objetivo com horário que cabe                     |
| C33 | Manda só um **áudio** perguntando preço                                    | Lê a transcrição e responde o preço                                |
| C34 | Pergunta **3 coisas numa mensagem** (preço, horário, se faz botox)         | Responde as 3                                                      |
| C35 | Some depois do preço (39% nunca agendam)                                   | Não manda 5 mensagens de cobrança; retomada só pela regra do salão |
| C36 | Pergunta algo que o cadastro não tem ("vocês fazem mega hair?")            | ASK_OWNER para o dono, não inventa                                 |

## Como a bateria roda

1. Salão-robô "William-robô" no DEV, configurado **pelo Eddy** conversando com o
   dono-robô (Parte A). Assim o teste da atendente usa o que o Eddy gravou — se
   o Eddy gravou errado, a atendente erra, e o erro aparece onde nasceu.
2. Cada caso da Parte B roda com uma cliente simulada nova (`simular_whatsapp`).
3. A conferência é pelo banco: mensagem que saiu, agendamento gravado, pergunta
   ao dono aberta, ficha anotada. Resposta bonita sem o registro certo = falha.
4. O resultado vai para `docs/relatorios/`, caso por caso: passou / falhou / por quê / o que mudou.
