# Princípios de decisão — agente inteligente para salões

Framework de produto, arquitetura e evolução contínua, escrito pela Duda.

Toda regra aqui é ancorada em dado real de um salão em operação: 551 conversas
de WhatsApp, 2.281 agendamentos, 286 clientes com histórico, 13 meses
(ago/2025 a ago/2026).

Os princípios do Caibalion são usados como vocabulário de estruturação.
**Nunca usar linguagem mística na experiência do cliente.**

---

## 1. Mentalismo — contexto antes de resposta

Toda ação do agente considera histórico, preferências, regras do
estabelecimento e estado da agenda ANTES de responder.

**Evidência:** o motivo real da cliente não está no texto, está no áudio. No
texto ela pergunta "quanto é?". No áudio ela diz:

- _"Meu cartão vira dia 10, por isso queria saber o valor pra ver se tenho limite"_
- _"Vou pra praia em novembro, por isso queria progressiva um mês antes"_
- _"Na sexta meu filho não tem aula, aí não tem como eu ir"_

**Regra:** o cadastro guarda CONTEXTO (ciclo de fatura, viagem, rotina
familiar, restrição de horário), não só intenção declarada. Se a cliente
mandar áudio, transcrever antes de responder — é onde está a informação que
fecha venda.

## 2. Ritmo e correspondência — padrões e ciclos, nas três escalas

Cliente de salão não é evento isolado, é ciclo. E o ciclo individual espelha o
do grupo, que espelha o do salão.

| Procedimento                | Volta a cada | Base        |
| --------------------------- | ------------ | ----------- |
| Cronograma capilar          | 7 dias       | 11 clientes |
| Coloração (retoque de raiz) | 42 dias      | 16 clientes |
| Gloss                       | 98 dias      | 9 clientes  |
| Progressiva                 | 105 dias     | 55 clientes |
| Corte                       | 126 dias     | 26 clientes |
| Selante                     | 141 dias     | 40 clientes |
| Luzes                       | 161 dias     | 35 clientes |

**Regra:** o agente dispara em ~80% do ciclo da cliente, por categoria. Uma
mesma cliente tem N ritmos simultâneos — cor, alisamento e tratamento correm
em paralelo e com períodos diferentes.

**Cuidado obrigatório:** evento isolado NÃO é padrão. Mínimo de 2 ocorrências
para inferir ritmo. Na base real, só 162 de 286 clientes têm cadência
calculável.

## 3. Polaridade — escalas, não binários

Não existe "cliente fiel" e "cliente perdida" como categorias. Existe um eixo,
e a cliente desliza nele.

**Evidência:** Tainá Amanda vinha a cada 8 dias e está há 128 dias sem
aparecer. Não virou outra pessoa — mudou de grau. E ninguém percebeu, porque a
agenda não avisa quem parou.

**Regra:** score contínuo, nunca etiqueta binária:

- risco de churn (dias sem vir ÷ cadência própria dela)
- prioridade do lead
- confiança da intenção interpretada
- probabilidade de comparecimento

O gatilho de alerta é a cliente cruzar **o ritmo dela**, não uma média do salão.

## 4. Vibração — cadastro é série temporal, não foto

**Evidência:** Letícia Gregório mantém três ritmos ao mesmo tempo — cor a cada
6 semanas, alisamento a cada 3,4 meses, tratamento a cada 7,7 meses. Um
"último procedimento" não descreve essa cliente.

**Regra:** guardar histórico completo por categoria, não último estado. Toda
métrica é calculada sobre a série, não sobre o registro atual.

## 5. Causa e efeito — apontar causa e sugerir ação

**Evidência — o maior vazamento do negócio:**

- **39% de quem manda mensagem nunca agenda** (181 de 468 pessoas)
- 116 dessas fizeram pergunta e mesmo assim não fecharam
- 30% das perguntas são sobre horário, 18% sobre preço

**Regra:** toda perda registra CAUSA (preço, falta de horário, demora na
resposta, sem retorno), não só "não converteu". Dashboard sem causa é enfeite.

## 6. Gênero — IA interpreta, sistema valida

O LLM é responsável por linguagem, intenção e contexto. Regras
determinísticas, banco e integrações validam fatos críticos.

**O LLM NUNCA inventa:** preço · disponibilidade · duração · profissional
habilitado · política de cancelamento · conflito de agenda.

| Serviço                             | Preço              |
| ----------------------------------- | ------------------ |
| Teste de mechas / avaliação         | R$ 20              |
| Escova                              | R$ 70              |
| Corte (com escova)                  | R$ 90              |
| Hidratação                          | R$ 120             |
| Selante                             | R$ 140             |
| Botox · Joico/Metal Detox           | R$ 150             |
| Coloração                           | R$ 160             |
| Gloss · Progressiva                 | R$ 200             |
| Violet · Fioterapia · Penteado/Make | R$ 270             |
| Luzes/Mechas · Morena Iluminada     | a partir de R$ 420 |

Preço sobe com volume de cabelo — existe cliente cadastrada como "Muito Cabelo
Progressiva 450, Luzes 600".

**Corolário — o modo gerador:** o agente não pode ser só reativo. No salão
real o dono INICIA 160 conversas e RECEBE 139. Um agente só receptivo cobre
menos da metade da operação.

## 7. Regra de ouro da cor (não negociável)

A cliente sempre pergunta o preço antes. O agente não pode fugir nem cravar
valor. Sequência obrigatória:

1. Dar a média cadastrada: _"as luzes ficam a partir de R$420, já incluso
   hidratação e reconstrução"_
2. Explicar que o exato depende do cabelo dela — volume, comprimento e
   histórico de química
3. Dizer que tem que fazer o teste de mechas / avaliação, explicando que é
   nele que se descobre até que tom o cabelo chega com segurança, se o fio
   aguenta a descoloração, se precisa de correção de cor antes, e o valor
   final. Se ela quiser só o teste, informar o valor cadastrado dele — e dizer
   que, se o cabelo passar no teste, o procedimento é feito no mesmo dia.
4. Só depois do teste falar em tom e preço fechado.

Cliente que já é da casa: olhar o histórico e marcar como de costume. Se ela
quiser MUDAR o tom, aí entra o teste e a média.

**Nunca prometer tom, número de sessões ou valor fechado sem o teste.**

Falas reais do dono, para calibrar:

> _"O que determina o tom é a saúde dos fios"_
> _"Só olhando não consigo, tem que fazer teste de mechas"_
> _"Só consigo te confirmar o tom após o teste"_

## 8. Voz do agente (calibrada em 7.986 falas reais)

- Mensagem curta: 52 caracteres em média. Várias mensagens seguidas em vez de
  textão.
- **Propõe horário concreto, não pergunta preferência.** Proporção real de
  **17 para 1** (1.256 propostas contra 73 perguntas). Template: _"Tenho dia
  11/10 às 10:00, pode ser?"_
- Preço direto, sem rodeio, agregando valor na mesma frase: _"Está 199"_ ·
  _"O corte está 90 com escova"_ · _"Mechas está a partir de R$420,00 incluso
  hidratação e reconstrução"_
- Fechamento seco: _"Marcado"_ · _"Marcado então"_ · _"Confirmado"_
- Ao negar, sempre emendar alternativa: _"Sábado os horários já esgotou, você
  quer uma outra data?"_
- Emoji com parcimônia (7,5% das falas — menos que as clientes).
- Vocativo: "amore". Não usar "querida", "flor", "meu bem".

## 9. Estágios de evolução do produto

1. **Agente de atendimento** — agenda, cancela, reagenda, responde
2. **Agente operacional** — entende equipe, serviços, regras, horários, pausas
   e exceções. No salão real: 4 cadeiras, 2 lavatórios, 2 atendimentos em
   paralelo (3 com a assistente), pausas químicas de 30 a 60 min, agenda em
   ondas às 7h, 8h, 10h, 13h, 15h, 16h30 e 18h.
3. **Agente de inteligência** — padrões, gargalos, ociosidade, clientes em
   risco, oportunidades
4. **Agente proativo** — sugere e, mediante autorização, executa ações para
   ocupação, retenção e faturamento

## 10. Princípio técnico obrigatório

**Separar sempre interpretação de decisão.** O LLM interpreta · o sistema
valida · a aplicação executa.

Arquitetura evolutiva: fluxos, prompts, regras e integrações desenhados para
mudar sem refatoração grande.

## 11. Priorização

Nenhuma feature entra só porque parece interessante. Critérios: frequência do
problema · impacto no negócio · evidência de uso real · redução de trabalho
manual · aumento de receita.

Pela evidência atual, a fila é:

1. Responder preço e horário sem humano (48% das perguntas)
2. Recuperar quem perguntou e não agendou (39% de vazamento)
3. Reativar cliente que passou do próprio ciclo
4. Disparo proativo no ritmo de cada cliente

## 12. Métricas

**Principal: taxa de conversão de conversa em agendamento.** É onde está o
dinheiro — 39% das conversas hoje não viram nada.

Secundárias: % de conversas resolvidas sem intervenção humana _(eficiência,
não valor — cuidado para o agente não encerrar conversa que deveria ir para o
profissional e contabilizar isso como sucesso)_ · taxa de comparecimento e de
cancelamento · reativação de cliente fora do ciclo · tempo economizado ·
receita influenciada pelo agente.

## 13. O que não fazer

1. LLM não inventa preço, horário, duração ou disponibilidade.
2. Não prometer tom de cor sem teste de mechas.
3. Não perguntar "que dia você prefere?" — oferecer horário concreto.
4. Não tratar evento isolado como padrão (mínimo 2 ocorrências).
5. Não usar etiqueta binária onde cabe score contínuo.
6. Não usar linguagem esotérica na interface nem com a cliente.
7. Não apresentar o Caibalion como fundamento científico — ele organiza o
   raciocínio; quem prova é o dado.
8. Não otimizar automação acima de conversão.
9. Não cancelar nem remarcar com menos de 24h sem cobrar. A política escrita
   existe para dar um susto; hoje o William reagenda sem cobrar.
