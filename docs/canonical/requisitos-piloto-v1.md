# Requisitos do Piloto sem Sinal - v1.1

**Produto:** SaaS multiempresa de agente de IA para negócios de beleza  
**Data de abertura:** 03 de agosto de 2026  
**Status:** em consolidação; dados do William recuperados do histórico  
**Baseline de origem:** `escopo-piloto-sem-sinal-v1.md`, aprovado em 03 de agosto de 2026  
**Pilotos de referência:** Salão do William e Studio da Jack

## 1. Finalidade deste documento

Especificar requisitos verificáveis para o piloto controlado, sem sinal e sem pagamento. O documento transforma necessidades particulares de William e Jack em configurações reutilizáveis por qualquer tenant.

Este documento não autoriza implementação. A modelagem de domínio e os contratos técnicos começam quando os requisitos operacionais indispensáveis estiverem consolidados e os conflitos de fonte que afetam o cálculo forem resolvidos. Dados já fornecidos não devem ser solicitados novamente.

### Correção da v1.1

A v1.0 encerrou o documento com três quadros vazios pedindo novamente dados do William. Isso foi incorreto: parte relevante dessas informações já constava no histórico e no dossiê do projeto. A v1.1 substitui os quadros por um perfil operacional recuperado, distingue configuração genérica de exemplo do tenant e isola apenas as divergências que realmente impedem um cálculo seguro.

## 2. Convenções

- `RF`: requisito funcional.
- `RNF`: requisito não funcional.
- `RN`: regra de negócio.
- `CA`: critério de aceite.
- `P0`: indispensável ao piloto.
- `P1`: necessário antes de liberar clientes reais, mas não bloqueia o primeiro simulador.
- `P2`: evolução posterior, fora do piloto atual.
- `Confirmado`: decisão aprovada ou informação operacional validada.
- `Pendente`: depende de resposta do estabelecimento.

Cada requisito descreve uma única obrigação. Um requisito só poderá receber status `Aprovado` quando houver critério de aceite testável e nenhuma ambiguidade operacional relevante.

## 3. Decisões herdadas e não reabertas

| ID      | Decisão                                                                    | Status     |
| ------- | -------------------------------------------------------------------------- | ---------- |
| DEC-001 | William é o primeiro tenant de referência.                                 | Confirmado |
| DEC-002 | Jack é o segundo tenant de referência.                                     | Confirmado |
| DEC-003 | Cada estabelecimento usa um calendário Google espelho no piloto.           | Confirmado |
| DEC-004 | Testes iniciais não alteram a agenda real.                                 | Confirmado |
| DEC-005 | Sinal e pagamento estão desativados para os dois pilotos.                  | Confirmado |
| DEC-006 | O WhatsApp aceita inicialmente somente o número da Duda.                   | Confirmado |
| DEC-007 | Todo dado de negócio pertence a um `tenant_id` desde a primeira migration. | Confirmado |
| DEC-008 | Configuração incompleta bloqueia a oferta de horários.                     | Confirmado |

## 4. Requisitos funcionais iniciais

### 4.1 Tenant, unidade e acesso

| ID         | Requisito                                                                                       | Prioridade | Status      |
| ---------- | ----------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-TEN-001 | O sistema deve cadastrar tenant com nome, status e fuso horário.                                |         P0 | Documentado |
| RF-TEN-002 | O sistema deve associar todo registro operacional a exatamente um `tenant_id`.                  |         P0 | Documentado |
| RF-TEN-003 | O sistema deve cadastrar ao menos uma unidade por tenant.                                       |         P0 | Documentado |
| RF-TEN-004 | O sistema deve permitir criar, editar, inativar e reativar usuários administrativos.            |         P0 | Documentado |
| RF-TEN-005 | O sistema deve controlar permissões por membership do usuário no tenant.                        |         P0 | Documentado |
| RF-TEN-006 | O sistema deve impedir exclusão física de registro que possua histórico operacional dependente. |         P0 | Documentado |
| RF-TEN-007 | O sistema deve permitir exclusão confirmada de cadastro incorreto que não possua dependências.  |         P0 | Documentado |

### 4.2 Expediente e prontidão

| ID         | Requisito                                                                                                         | Prioridade | Status      |
| ---------- | ----------------------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-CFG-001 | O sistema deve cadastrar zero ou mais faixas de funcionamento por dia da semana.                                  |         P0 | Documentado |
| RF-CFG-002 | O sistema deve cadastrar pausas, almoço, feriados e bloqueios por data e intervalo.                               |         P0 | Documentado |
| RF-CFG-003 | O sistema deve tratar o encerramento do expediente como término máximo do atendimento.                            |         P0 | Documentado |
| RF-CFG-004 | O sistema deve calcular a prontidão do tenant com base em um checklist versionado.                                |         P0 | Documentado |
| RF-CFG-005 | O sistema deve informar ao administrador quais configurações impedem o agendamento.                               |         P0 | Documentado |
| RF-CFG-006 | O sistema deve impedir consulta e proposta de horários quando a prontidão estiver inválida.                       |         P0 | Documentado |
| RF-CFG-007 | O sistema deve recalcular a prontidão após alteração relevante de equipe, serviço, recurso, agenda ou integração. |         P0 | Documentado |

### 4.3 Equipe e disponibilidade

| ID         | Requisito                                                                                           | Prioridade | Status      |
| ---------- | --------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-EQP-001 | O sistema deve cadastrar profissionais e assistentes como participantes operacionais distintos.     |         P0 | Documentado |
| RF-EQP-002 | O sistema deve cadastrar habilidades por participante e por etapa de serviço.                       |         P0 | Documentado |
| RF-EQP-003 | O sistema deve admitir várias faixas semanais por participante.                                     |         P0 | Documentado |
| RF-EQP-004 | O sistema deve admitir disponibilidade fixa, híbrida ou dinâmica.                                   |         P0 | Documentado |
| RF-EQP-005 | O sistema deve considerar participante ocasional somente durante turno confirmado com início e fim. |         P0 | Documentado |
| RF-EQP-006 | O sistema deve permitir substitutos por etapa com ordem de preferência configurável.                |         P0 | Documentado |
| RF-EQP-007 | O sistema deve impedir alocação fora do turno do participante.                                      |         P0 | Documentado |
| RF-EQP-008 | O sistema deve preservar o histórico ao inativar um participante.                                   |         P0 | Documentado |

### 4.4 Serviços, variações e etapas

| ID         | Requisito                                                                                           | Prioridade | Status      |
| ---------- | --------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-SRV-001 | O sistema deve cadastrar serviços simples e compostos como unidades vendáveis.                      |         P0 | Documentado |
| RF-SRV-002 | O sistema deve representar serviço composto por etapas ordenadas.                                   |         P0 | Documentado |
| RF-SRV-003 | O sistema deve cadastrar duração própria para cada etapa.                                           |         P0 | Documentado |
| RF-SRV-004 | O sistema deve cadastrar participantes aptos e substitutos para cada etapa.                         |         P0 | Documentado |
| RF-SRV-005 | O sistema deve cadastrar os recursos obrigatórios de cada etapa.                                    |         P0 | Documentado |
| RF-SRV-006 | O sistema deve registrar se cada etapa bloqueia ou libera cada participante e recurso.              |         P0 | Documentado |
| RF-SRV-007 | O sistema deve cadastrar dependências entre etapas.                                                 |         P0 | Documentado |
| RF-SRV-008 | O sistema deve cadastrar variações que alterem duração, preço ou perguntas obrigatórias.            |         P0 | Documentado |
| RF-SRV-009 | O sistema deve impedir publicação de serviço cuja duração não possa ser determinada.                |         P0 | Documentado |
| RF-SRV-010 | O sistema deve vincular preparo obrigatório ao serviço principal.                                   |         P0 | Documentado |
| RF-SRV-011 | O sistema deve cadastrar antecedência, duração, dias permitidos e impacto de capacidade do preparo. |         P0 | Documentado |
| RF-SRV-012 | O sistema deve preservar histórico ao inativar serviço, variação ou etapa já utilizados.            |         P0 | Documentado |

### 4.5 Recursos

| ID         | Requisito                                                                        | Prioridade | Status      |
| ---------- | -------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-REC-001 | O sistema deve cadastrar recursos exclusivos ou compartilhados.                  |         P0 | Documentado |
| RF-REC-002 | O sistema deve associar capacidade inteira positiva a cada recurso.              |         P0 | Documentado |
| RF-REC-003 | O sistema deve reservar recurso pelo intervalo real de cada etapa.               |         P0 | Documentado |
| RF-REC-004 | O sistema deve rejeitar candidato que exceda a capacidade simultânea do recurso. |         P0 | Documentado |

### 4.6 Motor determinístico de agenda

| ID         | Requisito                                                                                                   | Prioridade | Status      |
| ---------- | ----------------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-AGE-001 | O motor deve receber serviço resolvido, período de busca, tenant, unidade e contexto autorizado da cliente. |         P0 | Documentado |
| RF-AGE-002 | O motor deve montar a linha do tempo completa das etapas antes de avaliar disponibilidade.                  |         P0 | Documentado |
| RF-AGE-003 | O motor deve validar expediente, turnos, pausas, almoço, bloqueios, exceções e término máximo.              |         P0 | Documentado |
| RF-AGE-004 | O motor deve validar participantes e recursos em cada etapa.                                                |         P0 | Documentado |
| RF-AGE-005 | O motor deve considerar ocupações internas e externas sincronizadas.                                        |         P0 | Documentado |
| RF-AGE-006 | O motor deve rejeitar todo candidato que viole ao menos uma restrição obrigatória.                          |         P0 | Documentado |
| RF-AGE-007 | O motor deve retornar à LLM somente opções válidas e identificadas internamente.                            |         P0 | Documentado |
| RF-AGE-008 | O motor deve registrar a versão da configuração e as razões de aprovação ou rejeição de cada candidato.     |         P0 | Documentado |
| RF-AGE-009 | O sistema deve criar reserva temporária com prazo de expiração após a escolha da cliente.                   |         P0 | Documentado |
| RF-AGE-010 | O sistema deve impedir confirmações concorrentes para o mesmo participante ou recurso no mesmo intervalo.   |         P0 | Documentado |
| RF-AGE-011 | O sistema deve confirmar agendamento e etapas em uma transação.                                             |         P0 | Documentado |
| RF-AGE-012 | O sistema deve oferecer novas alternativas quando uma reserva expirar ou perder validade.                   |         P0 | Documentado |

### 4.7 Simulador

| ID         | Requisito                                                                                            | Prioridade | Status      |
| ---------- | ---------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-SIM-001 | O painel deve permitir simular uma solicitação sem WhatsApp e sem gravar na agenda real.             |         P0 | Documentado |
| RF-SIM-002 | O simulador deve usar a mesma configuração e o mesmo motor destinados à integração real.             |         P0 | Documentado |
| RF-SIM-003 | O simulador deve exibir etapas, alocações, recursos e motivos de rejeição dos horários.              |         P0 | Documentado |
| RF-SIM-004 | O simulador deve permitir confirmar em calendário espelho quando o modo de teste estiver habilitado. |         P0 | Documentado |

### 4.8 Google Calendar espelho

| ID         | Requisito                                                                                                                   | Prioridade | Status                 |
| ---------- | --------------------------------------------------------------------------------------------------------------------------- | ---------: | ---------------------- |
| RF-GCA-001 | O sistema deve conectar uma conta Google autorizada por tenant.                                                             |         P0 | Documentado            |
| RF-GCA-002 | O sistema deve mapear um calendário espelho principal por tenant no piloto.                                                 |         P0 | Documentado            |
| RF-GCA-003 | O sistema deve importar ocupações do calendário espelho de forma incremental.                                               |         P0 | Documentado            |
| RF-GCA-004 | O sistema deve criar, atualizar e cancelar eventos espelho de forma idempotente.                                            |         P0 | Documentado            |
| RF-GCA-005 | O sistema deve reconciliar periodicamente banco e calendário espelho.                                                       |         P0 | Documentado            |
| RF-GCA-006 | O sistema deve impedir confirmação automática quando não puder validar ocupações dentro da tolerância operacional aprovada. |         P0 | Pendente de tolerância |
| RF-GCA-007 | O sistema deve distinguir ocupação externa, evento criado pelo SaaS e bloqueio interno.                                     |         P0 | Documentado            |

### 4.9 Cliente, conversa e IA

| ID         | Requisito                                                                                                                           | Prioridade | Status      |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-CON-001 | O sistema deve identificar progressivamente a cliente pelo identificador recebido do WhatsApp.                                      |         P0 | Documentado |
| RF-CON-002 | A LLM deve extrair intenção e campos por saída estruturada validada.                                                                |         P0 | Documentado |
| RF-CON-003 | A LLM não deve produzir preço, duração, política, disponibilidade ou confirmação que não tenha sido fornecida por motor autorizado. |         P0 | Documentado |
| RF-CON-004 | O orquestrador deve perguntar somente o dado que bloqueia o próximo cálculo.                                                        |         P0 | Documentado |
| RF-CON-005 | O agente deve fazer no máximo uma pergunta objetiva por resposta.                                                                   |         P0 | Documentado |
| RF-CON-006 | O sistema deve processar áudio internamente e armazenar transcrição vinculada à mensagem.                                           |         P0 | Documentado |
| RF-CON-007 | O sistema deve transferir conversa para humano quando dados críticos permanecerem ambíguos.                                         |         P0 | Documentado |
| RF-CON-008 | O sistema deve permitir pausa por conversa.                                                                                         |         P0 | Documentado |
| RF-CON-009 | O sistema deve permitir pausa global de emergência por tenant.                                                                      |         P0 | Documentado |

### 4.10 WhatsApp em modo restrito

| ID         | Requisito                                                                                                 | Prioridade | Status                          |
| ---------- | --------------------------------------------------------------------------------------------------------- | ---------: | ------------------------------- |
| RF-WHA-001 | O sistema deve receber e enviar mensagens pela API oficial do WhatsApp.                                   |         P0 | Documentado                     |
| RF-WHA-002 | O sistema deve validar autenticidade do webhook conforme o contrato do provedor.                          |         P0 | Documentado                     |
| RF-WHA-003 | O sistema deve deduplicar mensagens recebidas pelo identificador externo.                                 |         P0 | Documentado                     |
| RF-WHA-004 | O sistema deve aceitar somente números presentes na allowlist enquanto estiver em modo restrito.          |         P0 | Documentado                     |
| RF-WHA-005 | O sistema deve rejeitar ou encaminhar com segurança mensagens de números não autorizados.                 |         P0 | Pendente de comportamento final |
| RF-WHA-006 | O sistema deve registrar status de envio, entrega, leitura e falha quando disponibilizados pelo provedor. |         P0 | Documentado                     |

### 4.11 Agendamento e mensagens finais

| ID         | Requisito                                                                                          | Prioridade | Status      |
| ---------- | -------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-AGD-001 | O sistema deve registrar serviço, variação, cliente, unidade, horário e linha do tempo das etapas. |         P0 | Documentado |
| RF-AGD-002 | O sistema deve permitir confirmação, cancelamento e remarcação no piloto.                          |         P0 | Documentado |
| RF-AGD-003 | A remarcação deve oferecer alternativas válidas e aguardar a escolha da cliente.                   |         P0 | Documentado |
| RF-AGD-004 | O sistema deve enviar mensagem final a partir de template configurável.                            |         P0 | Documentado |
| RF-AGD-005 | O template final deve interpolar somente campos validados.                                         |         P0 | Documentado |
| RF-AGD-006 | O sistema não deve criar estado ou dependência de pagamento no piloto.                             |         P0 | Documentado |

### 4.12 Auditoria e operação

| ID         | Requisito                                                                                                           | Prioridade | Status      |
| ---------- | ------------------------------------------------------------------------------------------------------------------- | ---------: | ----------- |
| RF-AUD-001 | O sistema deve registrar ator, tenant, ação, instante, dados mínimos de entrada e resultado de toda ação relevante. |         P0 | Documentado |
| RF-AUD-002 | O sistema deve registrar versão da configuração usada em cada cálculo de agenda.                                    |         P0 | Documentado |
| RF-AUD-003 | O sistema deve registrar falhas de integração e tentativas de recuperação.                                          |         P0 | Documentado |
| RF-AUD-004 | O sistema deve permitir correlação entre webhook, conversa, cálculo, reserva, agendamento e evento externo.         |         P0 | Documentado |

## 5. Requisitos não funcionais iniciais

| ID          | Requisito mensurável                                                                                          | Prioridade | Status              |
| ----------- | ------------------------------------------------------------------------------------------------------------- | ---------: | ------------------- |
| RNF-SEG-001 | Uma consulta autenticada por usuário do tenant A deve retornar zero registros do tenant B.                    |         P0 | Documentado         |
| RNF-SEG-002 | A chave privilegiada do backend não deve estar presente em bundle, log ou variável pública do frontend.       |         P0 | Documentado         |
| RNF-CON-001 | Cem tentativas concorrentes sobre a mesma última vaga devem produzir no máximo um agendamento confirmado.     |         P0 | Documentado         |
| RNF-IDM-001 | Reprocessar o mesmo webhook deve manter exatamente uma mensagem e uma ação lógica.                            |         P0 | Documentado         |
| RNF-FAL-001 | Falha de LLM, WhatsApp ou Google não deve gerar confirmação falsa.                                            |         P0 | Documentado         |
| RNF-AUD-001 | Toda confirmação deve ser rastreável da mensagem recebida até a versão da configuração e o evento externo.    |         P0 | Documentado         |
| RNF-PRV-001 | Texto, áudio e logs devem obedecer prazos de retenção configurados e processo auditável de exclusão.          |         P0 | Pendente de prazos  |
| RNF-OBS-001 | Erros de cálculo, fila, webhook e sincronização devem produzir evento observável com correlação.              |         P0 | Documentado         |
| RNF-USA-001 | Alterações administrativas salvas devem permanecer após recarregar a interface.                               |         P0 | Documentado         |
| RNF-EVO-001 | Nenhuma regra operacional deve depender de comparação com o nome William ou Jack no código.                   |         P0 | Documentado         |
| RNF-DSP-001 | A meta de disponibilidade e o limite de latência serão definidos após medição do simulador e antes do Gate D. |         P1 | Pendente de medição |

## 6. Regras de negócio confirmadas

| ID     | Regra                                                                                |
| ------ | ------------------------------------------------------------------------------------ |
| RN-001 | Sinal está desativado nos dois tenants do piloto.                                    |
| RN-002 | Fechamento é o limite máximo de término, não um horário permitido de início.         |
| RN-003 | Serviço composto permanece uma unidade vendável com etapas internas.                 |
| RN-004 | Uma etapa pode liberar o profissional e continuar ocupando recurso.                  |
| RN-005 | Participante ocasional só está disponível durante turno confirmado.                  |
| RN-006 | A existência ou cor de evento não prova, sozinha, disponibilidade de participante.   |
| RN-007 | Toda opção apresentada à cliente deve ter sido aprovada pelo motor determinístico.   |
| RN-008 | Configuração incompleta bloqueia oferta de horários.                                 |
| RN-009 | A escolha da cliente deve ser protegida por reserva temporária antes da confirmação. |
| RN-010 | Remarcação não pode impor horário sem escolha da cliente.                            |

## 7. Critérios de aceite transversais

### CA-001 - Bloqueio por configuração incompleta

**Dado** um tenant sem duração válida para uma etapa obrigatória  
**Quando** uma cliente solicitar disponibilidade para o serviço  
**Então** nenhum horário será oferecido  
**E** o administrador verá a configuração faltante  
**E** a conversa seguirá para tratamento seguro.

### CA-002 - Término máximo

**Dado** um estabelecimento que encerra às 19h  
**E** um serviço cuja linha do tempo dura três horas  
**Quando** o motor avaliar início às 17h  
**Então** o candidato será rejeitado porque terminaria às 20h.

### CA-003 - Pausa que libera pessoa e bloqueia recurso

**Dado** uma etapa de pausa que libera o profissional e mantém a cadeira ocupada  
**Quando** o motor avaliar outro atendimento no mesmo intervalo  
**Então** poderá reutilizar o profissional se todas as demais restrições permitirem  
**Mas** não poderá reutilizar a cadeira além de sua capacidade.

### CA-004 - Concorrência

**Dado** duas conversas escolhendo a última vaga simultaneamente  
**Quando** ambas tentarem confirmar  
**Então** somente uma confirmação será persistida  
**E** a outra conversa receberá alternativas recalculadas.

### CA-005 - Falha do calendário

**Dado** que as ocupações externas não podem ser validadas dentro da tolerância aprovada  
**Quando** o sistema tentar confirmar um horário  
**Então** a confirmação automática será bloqueada  
**E** nenhuma mensagem afirmará que o agendamento está confirmado.

### CA-006 - Isolamento

**Dado** um usuário autenticado apenas no tenant William  
**Quando** tentar consultar ou alterar registro do tenant Jack  
**Então** a operação será negada  
**E** nenhum dado do tenant Jack será retornado.

## 8. Rastreabilidade com a baseline

| Decisão da baseline                       | Requisitos relacionados                           |
| ----------------------------------------- | ------------------------------------------------- |
| Multiempresa desde o banco                | RF-TEN-002, RF-TEN-005, RNF-SEG-001, CA-006       |
| Configuração obrigatória antes de agendar | RF-CFG-004 a RF-CFG-007, RF-SRV-009, CA-001       |
| Serviços com etapas                       | RF-SRV-001 a RF-SRV-011, RF-AGE-002 a RF-AGE-004  |
| Motor determinístico                      | RF-AGE-001 a RF-AGE-012, RF-CON-003               |
| Calendário espelho                        | RF-GCA-001 a RF-GCA-007                           |
| WhatsApp restrito                         | RF-WHA-001 a RF-WHA-006                           |
| Sem sinal                                 | RF-AGD-006, RN-001                                |
| Falha segura e auditável                  | RF-AUD-001 a RF-AUD-004, RNF-FAL-001, RNF-AUD-001 |

## 9. Perfil operacional recuperado - William

Os itens abaixo são dados de configuração do primeiro tenant de referência. Eles não alteram o código do motor e não criam condicionais por nome de estabelecimento.

### 9.1 Origem e tratamento da evidência

| Nível             | Significado                                                                                               |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| Confirmado        | Informação afirmada pela fundadora e preservada no histórico ou no dossiê.                                |
| Conflito de fonte | Existem dois valores preservados para o mesmo conceito; o motor não pode escolher um deles por suposição. |
| Configurável      | A estrutura é requisito do produto; o valor pertence ao tenant William e pode ser alterado no painel.     |

### 9.2 Expediente, exceções e término

| ID              | Informação recuperada                                                                              | Tratamento no produto                                                                                                                             | Status               |
| --------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| CFG-WIL-EXP-001 | Foram informadas várias faixas semanais, com terça a sexta das 09h às 18h e sábado das 08h às 18h. | Registros em faixas semanais pertencentes ao tenant, editáveis no painel.                                                                         | Confirmado no dossiê |
| CFG-WIL-EXP-002 | Também foi preservada a descrição 09h–12h e 13h–19h.                                               | Não sobrescrever CFG-WIL-EXP-001. Manter como fonte divergente até identificar se descreve expediente do salão, turno de William ou regra antiga. | Conflito de fonte    |
| CFG-WIL-EXP-003 | Todos os procedimentos devem terminar até 19h.                                                     | `latest_service_end_time = 19:00`; não representa horário permitido para começar.                                                                 | Confirmado           |
| CFG-WIL-EXP-004 | Algumas clientes podem ser atendidas no sábado às 07h, fora do horário normal.                     | Exceção aprovada com data, cliente, serviço, profissional, início e validade; nunca alteração silenciosa do expediente geral.                     | Confirmado           |
| CFG-WIL-EXP-005 | O sistema deve aceitar almoço e turnos quebrados.                                                  | Faixas e bloqueios configuráveis; nenhum intervalo é presumido enquanto a configuração vigente não estiver selecionada.                           | Configurável         |

O único bloqueio de fonte nesta parte é decidir qual descrição representa o expediente vigente. Isso não impede modelar nem implementar o configurador genérico; impede apenas ativar o tenant William para oferecer horários reais.

### 9.3 Equipe e capacidade

| ID              | Informação recuperada                                                                                         | Tratamento no produto                                                                                                         | Status                      |
| --------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| CFG-WIL-EQP-001 | William é o profissional principal do salão.                                                                  | Participante operacional com habilidades associadas por etapa.                                                                | Confirmado                  |
| CFG-WIL-EQP-002 | Existe uma assistente fixa.                                                                                   | Disponibilidade semanal fixa ou híbrida, cadastrada por faixas.                                                               | Confirmado                  |
| CFG-WIL-EQP-003 | Existe uma segunda assistente ocasional/dinâmica.                                                             | Participante com disponibilidade dinâmica; não entra no cálculo sem turno confirmado.                                         | Confirmado                  |
| CFG-WIL-EQP-004 | A assistente dinâmica costuma ir a cada quinze dias aos sábados ou quando o sábado está cheio e ela confirma. | Recorrência pode sugerir turno, mas somente a confirmação com data, início e fim gera capacidade.                             | Confirmado                  |
| CFG-WIL-EQP-005 | A entrada e a saída da assistente dinâmica variam por turno e são controladas na agenda.                      | Evento de disponibilidade com início e fim reais; cor do evento não é evidência suficiente.                                   | Confirmado                  |
| CFG-WIL-EQP-006 | A presença de assistente aumenta a capacidade de atendimento.                                                 | O efeito deve resultar das etapas que ela pode executar e dos recursos disponíveis, nunca de um multiplicador fixo no código. | Confirmado como necessidade |
| CFG-WIL-EQP-007 | Nas etapas deve ser possível indicar qualquer profissional apto.                                              | Relação genérica etapa–habilidade–participante, com substitutos e preferência.                                                | Confirmado                  |

### 9.4 Serviço composto recuperado

**Serviço vendável:** progressiva sem formol.

| Ordem | Etapa recuperada | Duração | Regra de modelagem                                                                            |
| ----: | ---------------- | ------: | --------------------------------------------------------------------------------------------- |
|     1 | Lavagem          |  20 min | Etapa interna do serviço, não serviço vendável isolado.                                       |
|     2 | Pausa            |  60 min | Deve declarar separadamente se libera William/assistente e quais recursos continuam ocupados. |
|     3 | Escova           |  25 min | Participantes aptos e recursos são configurados por etapa.                                    |
|     4 | Chapinha         |  90 min | Participantes aptos e recursos são configurados por etapa.                                    |

A duração sequencial recuperada soma **195 minutos (3h15)** antes de qualquer ajuste configurado por cabelo, técnica, condição, preparação ou execução paralela. A LLM não pode alterar esse total por conta própria.

### 9.5 Preparação: teste de mechas

| ID              | Informação recuperada                                                                           | Tratamento no produto                                                                                                    | Status                                                              |
| --------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| CFG-WIL-PRE-001 | Para determinados cabelos, William pode propor teste de mechas antes do procedimento de sábado. | Preparação vinculada ao serviço principal, condicionada por regra de elegibilidade.                                      | Confirmado                                                          |
| CFG-WIL-PRE-002 | O teste pode ocorrer de terça a sexta antes do sábado.                                          | Janela de antecedência e dias permitidos configuráveis.                                                                  | Confirmado                                                          |
| CFG-WIL-PRE-003 | O teste dura em média uma hora.                                                                 | Duração base de 60 minutos para o preparo, editável pelo tenant.                                                         | Confirmado                                                          |
| CFG-WIL-PRE-004 | Foi informado que o teste não impacta a produção.                                               | Modelar tempo ativo e tempo de espera separadamente; não reservar toda a hora de William ou de um recurso por suposição. | Confirmado, com decomposição operacional necessária no configurador |

### 9.6 Classificação de cabelo e variações

O produto deve permitir que o estabelecimento configure comprimento, volume, textura, condição, técnica e outras características que alterem pergunta, duração ou preço. Para o caso do William, foram explicitamente exigidas as classes:

- comprimento: curto, médio e longo;
- volume: pouco, médio e muito.

Cada classe precisa aceitar descrição, referências visuais, perguntas de confirmação e seus efeitos determinísticos. A classificação por IA deve retornar confiança e pedir confirmação quando a consequência de preço ou duração for relevante.

Os valores exatos das descrições fornecidas pelo William não estão reproduzidos no material atualmente preservado neste workspace. Isso não autoriza uma nova entrevista completa nem uma invenção: eles devem ser transcritos da conversa-fonte quando ela estiver disponível e depois cadastrados pelo mesmo configurador usado por qualquer tenant.

### 9.7 Políticas já decididas para o piloto

| Política                 | Valor no tenant William durante o piloto                              |
| ------------------------ | --------------------------------------------------------------------- |
| Sinal                    | Desativado                                                            |
| Pagamento para confirmar | Desativado                                                            |
| WhatsApp                 | Restrito ao número da Duda                                            |
| Google Calendar          | Um calendário espelho; agenda real não é alterada nos testes iniciais |
| Confirmação              | Somente após reserva persistida e cálculo determinístico válido       |

Regras de sinal mencionadas anteriormente — como dezembro, penteado ou maquiagem — permanecem capacidade futura do produto e não participam do fluxo de confirmação deste piloto.

## 10. Resultado da consolidação do William

Não é necessário repetir as três perguntas amplas da v1.0. A configuração e a modelagem podem avançar com os dados já recuperados.

Restam somente dois controles de qualidade antes de ativar o tenant William em um piloto real:

1. Resolver qual das duas descrições de expediente representa a configuração vigente e qual representa turno, intervalo ou regra antiga.
2. Transcrever, sem reinterpretar, as descrições exatas já fornecidas para comprimento e volume quando a conversa-fonte estiver acessível.

Esses controles não justificam reabrir sinal, calendário, equipe, progressiva, teste de mechas, exceção das 07h, término às 19h ou a arquitetura configurável e multiempresa.
