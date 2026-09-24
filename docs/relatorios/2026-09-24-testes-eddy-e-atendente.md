# Relatório de testes — Eddy e atendente (24/09/2026)

**Situação:** testes do Eddy (dono) concluídos até a publicação. Testes da atendente (clientes) **interrompidos às 15:29** — o crédito da API da Anthropic acabou. Nada do agente responde em nenhum salão até recarregar.

## Como foi testado

- **Canal simulado** (migração `20260924141224`): um número falso passa pela mesma corrente de produção — webhook → projeção → leitura de mídia → agente → fila de envio — e a saída é marcada como enviada **sem chamar a Meta**. Fotos simuladas são lidas pela mesma IA de visão (usei as 5 fotos reais que você mandou hoje).
- **Salão-robô** do zero: "Robo 1", dono "Rogério" (5599900000001), salão colorista com 3 pessoas.
- Toda afirmação do Eddy ("anotei", "gravado", "confirmado") foi conferida **no banco** logo depois.

## Parte 1 — Eddy com o dono-robô (27 turnos)

| # | Dono mandou | Eddy fez | Banco (prova) |
|---|---|---|---|
| 1 | "Oi, a Duda falou que você ia me ajudar" | Ofereceu texto ou áudio; perguntou o que o agente deve fazer | — |
| 2 | Marca na agenda, sem sinal, cancelamento <24h paga 50% | Anotou as 3 decisões | `agent_scope` marca=true, sinal=false, cancel=true; regra "Cancelamento com menos de 24h" |
| 3 | Nome + endereço **sem estado** | "Ribeirão Preto é em SP, certo?" | não gravou sem UF ✔ |
| 4 | "Isso, SP" | Gravou | unidade "Studio Rogério Hair", Rua das Palmeiras 150, SP ✔ |
| 5 | Equipe de 3 com funções | Gravou | 3 pessoas, 7 habilidades, 7 ligações ✔ |
| 6 | Horários **por áudio** | Gravou | 5 dias (ter–sáb) ✔ |
| 7 | Disponibilidade mista (fixo / 3 dias / sem dia fixo) | Gravou | Rogério ter–sáb, Carla ter/qui/sáb, Bia sem dia ✔ |
| 8–9 | 11 serviços com preço + durações e pausas **por áudio** | Criou tudo | 10 serviços; escova com 3 variações de preço; pausas de química ✔ |
| 11 | Botox: 30 min de pausa, "dá pra pegar outra" | Gravou | pausa livre ✔ |
| 12 | Mechas: 45 min de pausa, "fico de olho, não dá pra pegar outra" | Disse "não dá pra encaixar" | **gravou como LIVRE ✘** → corrigido (item 6 abaixo) |
| 13 | "Confere que nas mechas a agenda NÃO marca outra?" | "Confirmado" | **continuava LIVRE ✘** — confirmou de memória → corrigido (item 7) |
| 14–15 | "Confere de novo no sistema" / "corrige" | Leu o banco, viu o erro, ofereceu corrigir e corrigiu | pausa das mechas OCUPADA ✔ |
| 16 | 3 fotos reais **sem legenda** | Leu "ruivo acobreado, 0,85" e arquivou em Ruivo | 3 fotos em Ruivo ✔ (arquivou sem esperar confirmação) |
| 17 | 9 respostas de cor **num áudio** | Extraiu as 9 certinho, pediu confirmação | — |
| 18 | "Confere sim" | **"Show, cor gravada certinho"** | **NADA gravado ✘✘** → corrigido (item 8) |
| 19 | "Ficaram no sistema?" (após correção) | "Ficaram sim" | 9/9 respostas de cor ✔ |
| 20 | 4 regras num áudio (gestante, atraso, pagamento, platinado) | Gravou | 4/4 regras ✔ |
| 21 | Texto de confirmação com dados de exemplo | Trocou por lacunas {nome} {servico} {data} {hora} {salao} {endereco} | mensagem de confirmação gravada ✔ |
| 22 | Lembrete 19h + texto próprio | Ativou; explicou que texto próprio precisa de aprovação | lembrete=true, 19h, texto pedido ✔ |
| 23 | Instagram como URL completa | Gravou | `@studiorogeriohair` + link ✔ |
| 24 | (resumo antes de publicar) | **"seg a sex"** | banco certo (ter–sex); resumo lia número do dia errado → corrigido (item 12) |
| 25–26 | "Pode publicar" | Passou para você 2x | publicação travada → corrigido (itens 9 e 10) |
| 27 | "Pode publicar?" | "Publicado!" | **versão 1 no ar**: 10 serviços, confirmação, limites dos 5 dias, 5 regras ativas ✔ |

## Parte 2 — Atendente com clientes-robô (1 rodada, depois o crédito acabou)

| Cliente | Caso | Resultado |
|---|---|---|
| 101 | 4 perguntas juntas (preço escova, sábado, endereço, estacionamento) | ✔ sábado ✔ endereço **✘ "escova não tem valor fechado"** (tem 70/90/120) → corrigido (item 13) **✘ ignorou estacionamento** |
| 102 | Foto de ruivo, "castanho escuro virgem, quanto fica?" | Reconheceu o ruivo; ofereceu "Mechas a partir de 450"; **não citou teste de mecha** (a regra do dono exige a partir de 3 tons) |
| 103 | Escova sábado, cabelo médio | Pediu foto do cabelo (atrito: ela já disse "médio") |
| 104 | Gestante quer progressiva | ✔ recusou pela regra do dono |
| 105 | Áudio: cabelo preto virgem quer platinado | ✔ transcreveu e recusou pela regra; não ofereceu alternativa |
| 106 | Vídeo | ✔ "não abriu, me manda uma foto" |

**Não testado ainda** (bloqueado pelo crédito): agendar até cair na agenda, mensagem de finalização, lembrete de véspera, pergunta ao dono no meio do atendimento.

## O que precisei mudar (tudo na `dev`, aplicado e com deploy)

1. **Pauta com ~40 itens atropelava o roteiro.** O Eddy pulou redes sociais 3 vezes. Agora a próxima pergunta vem do roteiro e os detalhes entram por etapa. Também reduz tokens por turno.
2. **Pauta perguntava de novo** regra já em rascunho e sinal que o dono recusou.
3. **Bloco de prompt com ordem própria desatualizada** (6 itens, sem redes, confirmação e lembrete).
4. **Redes sociais** foram para o fim do roteiro, porque não destravam nada.
5. **Lote grande morria em SEM_DECISAO.** 11 serviços num áudio: gravava e o dono ficava sem resposta. Agora são 8 voltas e a última só responde.
6. **Pausa sem opção "profissional ocupada".** Toda pausa virava tempo livre na agenda.
7. **Eddy confirmava sem ler o banco.** Agora recebe o cadastro gravado em todo turno.
8. **Trava do "anotei sem gravar" furada.** Não pegava "gravada" e não contava gravações de cor, regra e redes.
9. **Publicar exigia "limite do último atendimento"**, e o Eddy não tinha como gravar isso. Todo salão configurado por conversa travaria no último passo. Agora o limite é o horário de fechar. O S-Eduarda tinha esse mesmo bloqueio escondido.
10. **Publicar exige e-mail do dono ligado ao número**, e o erro dizia "número não reconhecido", o que é falso. O S-William foi cadastrado sem e-mail e travaria igual.
11. **Nome do salão para a cliente.** Lembrete e finalização usavam o nome de cadastro ("S-William"), não o nome que o dono dá.
12. **Escova com preço só na variação** travava a etapa de preços.
13. **Atendente não via preço por variação nem "a partir de"**, e o Eddy dizia ter gravado "a partir de" sem ter ferramenta para isso.
14. **Atendente não sabia o endereço do salão.** O contexto dela só tinha nome e segmento.
15. **Mensagem de finalização existia no banco e ninguém enviava.** Agora sai depois do "marcado", com texto e/ou arte do dono.
16. **Eu causei uma parada de 2 min no envio** de todos os salões (14:14–14:16, coluna ambígua). Corrigi; na fila só havia mensagens simuladas.

## Pendências abertas (não corrigidas ainda)

- **"A atendente já responde a partir de agora"** depois de publicar: falso, porque a atendente do salão nasce desligada. Ou a publicação liga, ou o Eddy para de afirmar.
- **Duas perguntas na mesma resposta** em alguns turnos (regra: uma por mensagem).
- **Fotos sem legenda arquivadas sem confirmar** com o dono (acertou, mas pode errar).
- **Regra gravada via `anotar` fica ativa sem publicar**; via `criar_regra`, fica em rascunho.
- **Variação de serviço não tem duração própria**: a escova longa (90 min) entra na agenda com 40 min.
- **Atendente ignora pergunta que não sabe** (estacionamento) em vez de dizer que vai confirmar.
- **Cor**: não cruzou foto + "castanho escuro virgem" com a regra de teste de mecha.

## Custo medido hoje

| | Turnos | Custo | Média/turno |
|---|---|---|---|
| Eddy no robô (onboarding completo) | 27 | US$ 1,68 | US$ 0,062 |
| Eddy no S-Eduarda (seu teste das fotos) | 7 | US$ 0,49 | US$ 0,070 |
| Atendente no robô | 6 | US$ 0,25 | US$ 0,042 |

Configurar um salão inteiro pelo Eddy custou **≈ US$ 1,70** (≈ R$ 9,50).

## Estado do William

- Salão **S-William** criado do zero (vazio, com régua de cor e corte), dono William (16 98151-5089, gravado com e sem o 9).
- **O e-mail dele está provisoriamente ligado ao seu** (eddigital.oficial@gmail.com), para a publicação não travar. Preciso do e-mail do William para trocar.
- O número 7035 **ainda está no S-Eduarda**. Só mudo quando os testes da atendente passarem.
- O "Salão do William" antigo ficou intacto. Ele estava vazio (0 serviços); o que tem estrutura de verdade é o "Piloto Eduarda".
