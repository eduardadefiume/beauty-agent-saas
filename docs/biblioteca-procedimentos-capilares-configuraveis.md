# Biblioteca de Procedimentos Capilares Configuráveis

**Status:** especificação de catálogo; não é protocolo clínico, receita química nem instrução de aplicação.  
**Uso no SaaS:** cada estabelecimento cria suas fichas a partir de templates, vincula produtos e instruções aprovadas e escolhe as etapas que realmente executa.  
**Princípio:** a IA só consulta fichas publicadas e encaminha para avaliação humana quando faltam pré-requisitos ou há incerteza.

> O mesmo nome comercial pode esconder fórmulas, riscos, passos, pausas e cuidados posteriores diferentes. Por isso, o produto modela **etapas e parâmetros versionados**, e não “uma receita de progressiva”, “uma receita de loiro” ou “um tempo de pausa universal”. [1] [2] [3]

## 1. Estrutura comum de uma ficha de procedimento

| Grupo de etapa | Função no sistema | Dados configuráveis |
|---|---|---|
| Triagem | Descobrir se há segurança e contexto suficiente para atender | pergunta, resposta, sinal de alerta, obrigatório, responsável pela revisão |
| Preparação | Tornar o cabelo e o posto de trabalho aptos ao serviço | lavagem, proteção, produto, recurso, profissional, duração |
| Execução | Fazer o serviço ou uma etapa técnica interna | ordem, técnica interna, profissional apto, recurso e duração |
| Espera/processamento | Representar uma pausa sem inventar tempo | regra por produto/variação, bloqueio de cadeira/profissional, temporizador e checagem |
| Finalização | Encerrar tecnicamente e registrar resultado | enxágue quando a ficha exigir, secagem, acabamento, orientação e foto consentida |
| Pós-atendimento | Sustentar CRM e recorrência | serviço executado, fórmula/produto, data, próxima janela sugerida e observação |

O mecanismo deve permitir condição, ramificação, repetição, dependência, cancelamento e exceção aprovada. Uma etapa de espera pode liberar o profissional para outro atendimento, mas manter a cadeira ou o recurso indisponível; isso só acontece se a ficha declarar essa política.

## 2. Templates iniciais de procedimentos

### 2.1 Consulta, corte e finalização

| Ordem | Etapa modelo | Condição/saída configurável |
|---|---|---|
| 1 | Recepção e objetivo de resultado | referência desejada, orçamento, evento/data, profissional escolhido |
| 2 | Avaliação de cabelo e histórico relevante | comprimento, densidade, textura declarada, técnica prévia, restrição informada |
| 3 | Definição de variação e preço | faixa configurada; aprovação do cliente quando houver variação |
| 4 | Preparação/lavagem opcional | produto, lavatório, duração e profissional responsável |
| 5 | Corte | técnica cadastrada, profissional apto, duração-base e adicionais |
| 6 | Secagem/finalização opcional | escova, difusor, modelagem, recurso e duração |
| 7 | Validação e registro | confirmação de execução, foto opcional, preferência e janela de retorno comercial |

### 2.2 Escova, modelagem e penteado

| Ordem | Etapa modelo | Configurações relevantes |
|---|---|---|
| 1 | Triagem de comprimento, densidade e objetivo | determina faixa de duração/preço sem a IA improvisar |
| 2 | Lavagem/preparo opcional | lavatório, produto, proteção térmica e tempo |
| 3 | Pré-secagem | secador e responsável; pode liberar lavatório |
| 4 | Divisão e modelagem | técnica, ferramentas, recursos e duração por variação |
| 5 | Fixação/acessórios | material, custo adicional, aprovação de orçamento |
| 6 | Finalização e instrução de conservação | orientação aprovada e data/evento quando existir |

### 2.3 Tratamento cosmético de manutenção

| Ordem | Etapa modelo | Configurações relevantes |
|---|---|---|
| 1 | Triagem e objetivo | ressecamento percebido, rotina declarada, restrições e expectativa |
| 2 | Limpeza/preparo | produto de abertura/limpeza quando a ficha exigir |
| 3 | Aplicação do tratamento | produto/linha, lote opcional, responsável e recurso |
| 4 | Pausa/processamento | tempo por produto/variação, timer, recurso e bloqueio da estação |
| 5 | Enxágue/finalização | obrigatório/opcional conforme ficha de produto |
| 6 | Registro de execução e janela de retorno | observação, resultado e regra comercial configurável |

### 2.4 Coloração de raiz, tonalização ou cor global

| Ordem | Etapa modelo | Guardrail obrigatório |
|---|---|---|
| 1 | Anamnese e histórico químico informado | não permitir decisão automática de fórmula |
| 2 | Checagem de teste de alergia/mecha quando a política exigir | guardar data, produto, resultado, responsável e validade configurada |
| 3 | Seleção humana de serviço, produto e variação | vincular instrução do fabricante e profissional apto |
| 4 | Preparação e proteção | EPI/recurso conforme ficha do estabelecimento |
| 5 | Aplicação e processamento | timer configurado pela ficha; nenhuma duração é sugerida pela LLM |
| 6 | Verificação profissional, enxágue e tratamento pós | somente quando a etapa foi marcada como executada |
| 7 | Registro técnico e cuidados | produto/variação, data, foto consentida, duração real e regra de retorno |

O template exige avaliação e testes quando a política do estabelecimento ou a ficha de produto determinar. Materiais de fabricante recomendam teste de alergia e de mecha para orientar segurança, resultado e tempo; uma reação é gatilho de interrupção e escalonamento profissional. [1]

### 2.5 Descoloração, mechas e técnicas de iluminação

O fluxo é semelhante ao de coloração, porém o modelo deve comportar múltiplas seções, ciclos de avaliação humana, aditivos como pré-pigmentação/matização e recursos simultâneos. O agente conversa sobre intenção e agenda avaliação quando faltam dados; não promete tom, integridade do fio, duração final ou preço em cenário sem ficha de avaliação aprovada.

| Ordem | Etapa modelo | Regra de sistema |
|---|---|---|
| 1 | Consulta/viabilidade | exigir histórico e política de teste vinculada |
| 2 | Orçamento por faixa ou avaliação | registrar validade do orçamento e condições |
| 3 | Preparo e divisão | profissional, recursos e duração |
| 4 | Aplicação por técnica | subetapas repetíveis e rastreáveis |
| 5 | Processamento e revisões humanas | timer; bloqueio de avanço automático |
| 6 | Enxágue, tratamento, tonalização/matização | cada um é etapa independente e opcional |
| 7 | Finalização, registro e retorno | dados executados; não apenas dados previstos |

### 2.6 Alinhamento, redução de volume e tratamentos sem formol

Esse template só pode ser publicado por profissional responsável após vincular o produto regular e sua instrução. A Anvisa alerta que “progressiva”, “escova inteligente” ou nomenclaturas similares não garantem regularidade e que formol/glutaraldeído não devem ser usados como alisantes. [4] [5]

| Ordem | Etapa modelo | Regra de segurança/configuração |
|---|---|---|
| 1 | Consulta, histórico e avaliação humana | bloqueio se houver informação conflitante ou incompleta definida pela política |
| 2 | Checagem de produto, qualificação e ambiente | produto, instrução, responsável, ventilação/EPI e validade |
| 3 | Teste/preparo, quando exigido | resultado é registrado e revisado por humano |
| 4 | Limpeza/lavagem | só aparece se a ficha de produto exigir |
| 5 | Secagem parcial e divisão | duração, recurso e responsável configurados |
| 6 | Aplicação | instrução interna aprovada; sem gerar fórmula no chat |
| 7 | Pausa | definida por produto e variação; libera ou bloqueia recursos conforme política |
| 8 | Secagem/selagem térmica | parâmetros somente da ficha aprovada; verificação humana obrigatória |
| 9 | Enxágue/finalização | condicional à ficha; nunca suposto pelo agente |
| 10 | Cuidados, restrições e revisão | mensagem de pós-serviço aprovada e regra de retorno comercial |

Exemplos de fabricantes confirmam que existem fluxos distintos: um tratamento pode mandar enxaguar antes de finalizar, outro pode orientar esperar antes de lavar, e tempo/temperatura podem depender da textura e condição. Logo, o produto não pré-preenche esses valores como verdade universal. [2] [3]

### 2.7 Relaxamento, permanente e outras mudanças de textura

Compartilha os controles de química do template anterior, acrescidos de compatibilidade, neutralização quando aplicável e checkpoints humanos. O SaaS deve permitir que uma ficha bloqueie agendamento pelo agente e exija avaliação presencial para primeira aplicação, histórico químico ausente, teste pendente ou política do estabelecimento.

### 2.8 Extensões, manutenção e remoção

| Ordem | Etapa modelo | Configurações relevantes |
|---|---|---|
| 1 | Consulta e escolha de método/material | método, quantidade, cor, valor de material, regra de sinal |
| 2 | Avaliação e preparo | condição, comprimento, recurso e profissional apto |
| 3 | Aplicação/manutenção/remoção | subtarefas, duração e assistente opcional |
| 4 | Corte, mistura e finalização | adicionais e recursos |
| 5 | Orientação e janela de manutenção | regra comercial por método e condição informada |

## 3. Parâmetros de precificação e duração

Preço e duração podem depender de uma matriz publicada pelo estabelecimento. A matriz pode usar comprimento, densidade, espessura, técnica, histórico de serviço, profissional, unidade, data, adicional e avaliação aprovada. O agente só calcula se existir correspondência exata; caso contrário, diz que depende de avaliação e oferece a ação permitida.

| Parâmetro | Valores possíveis | Fonte |
|---|---|---|
| Comprimento | faixas nomeadas e próprias do tenant | selecionado pela cliente, profissional ou foto com revisão |
| Densidade/volume | baixa, média, alta ou escala do tenant | declarado/revisado, com confiança |
| Textura/padrão | taxonomia do tenant | declarado/revisado; nunca inferência final obrigatória |
| Histórico | virgem, colorido, químico, desconhecido ou categorias do tenant | cliente + profissional |
| Técnica | variação do serviço | catálogo publicado |
| Adicional | raiz, matização, pré-pigmentação, prova etc. | regra/cotação aprovada |

## 4. Eventos que alimentam o CRM

O sistema só atualiza “último procedimento”, duração observada e elegibilidade de retorno após o atendimento passar para `EXECUTADO`. A agenda, por si, apenas expressa intenção. Cada execução referencia a versão da ficha de serviço e as etapas efetivamente concluídas, permitindo explicar ao proprietário por que a cliente entrou em uma campanha.

## Referências

[1] [Wella — Hair color safety tests](https://www.wella.com/international/wella-magazine/hair-color-safety-tests).  
[2] [CHI Education — Enviro-American Smoothing Treatment](https://education.chi.com/online-courses/chapter-11-salon-texture-services/lessons/chi-enviro/).  
[3] [Brazilian Blowout — Professional treatment steps](https://rewards.brazilianblowout.com/thingstoknow/steps/).  
[4] [Anvisa — Produtos alisantes e ondulantes para cabelo](https://www.gov.br/anvisa/pt-br/comunicacao/campanhas/estetica/produtos-alisantes-e-ondulantes-para-cabelo).  
[5] [Anvisa — Alerta sobre alisantes irregulares](https://www.gov.br/anvisa/pt-br/assuntos/noticias-anvisa/2025/anvisa-alerta-para-riscos-a-saude-associados-ao-uso-de-alisantes-capilares-irregulares).  
