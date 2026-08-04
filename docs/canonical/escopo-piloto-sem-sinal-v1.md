# Escopo do Piloto sem Sinal — v1.0

**Produto:** SaaS multiempresa de agente de IA para negócios de beleza  
**Data da baseline:** 03 de agosto de 2026  
**Status:** aprovado pela fundadora e congelado como baseline  
**Aprovação:** 03 de agosto de 2026  
**Pilotos de referência:** Salão do William e Studio da Jack

## 1. Decisões executivas fechadas

1. O primeiro estabelecimento de referência é o **Salão do William**.
2. O segundo estabelecimento de referência é o **Studio da Jack**. As descrições anteriores “Jack” e “studio de lash designer com duas manicures” se referem ao mesmo piloto, não a dois estabelecimentos diferentes.
3. Cada estabelecimento usa **uma única agenda Google** no escopo do piloto.
4. Os primeiros testes usam **um calendário espelho**, separado da agenda real. Nenhum teste inicial pode criar, editar ou excluir eventos na agenda real de William ou Jack.
5. William e Jack **não cobrarão sinal no piloto**. O agendamento não terá estado de pagamento nem dependerá de provedor financeiro.
6. O primeiro atendimento via WhatsApp fica restrito ao **número da Duda**, usado para simular clientes e executar cenários controlados.
7. O produto nasce multiempresa: todo dado de negócio terá `tenant_id` e isolamento desde a primeira migration, mesmo antes de haver clientes pagantes.
8. O sistema não pode oferecer horário até que a configuração necessária do estabelecimento esteja completa e aprovada.

## 2. Objetivo do piloto

Comprovar, em ambiente controlado, que o sistema consegue transformar uma solicitação recebida pelo WhatsApp em um agendamento válido, sem conflito e sem intervenção manual obrigatória no caminho feliz.

O ciclo mínimo a validar é:

> configurar estabelecimento → interpretar pedido → coletar somente dados indispensáveis → calcular horários → propor alternativas válidas → receber escolha → reservar → confirmar → sincronizar no calendário espelho → enviar mensagem final.

O piloto não existe para provar que a IA conversa de forma impressionante. Ele existe para provar que o motor oferece somente horários executáveis.

## 3. Hipótese a ser validada

Se o estabelecimento configurar corretamente expediente, equipe, serviços, etapas, recursos, pausas, turnos e exceções, então uma cliente poderá solicitar um atendimento por texto ou áudio e receber opções de horários que respeitem todas as restrições reais da operação.

O piloto falha se gerar qualquer conflito evitável, ainda que a conversa pareça natural.

## 4. Limites do piloto

### 4.1 Incluído

- Dois tenants configurados separadamente: William e Jack.
- Painel administrativo persistente para os cadastros indispensáveis ao agendamento.
- Serviços simples e compostos.
- Variações que alterem duração, preço ou perguntas obrigatórias.
- Etapas ordenadas com profissionais, assistentes, recursos, bloqueio/liberação e dependências.
- Expediente por dia, múltiplas faixas, intervalos, almoço, bloqueios, feriados e exceções.
- Profissionais com disponibilidade fixa, híbrida ou dinâmica.
- Turnos ocasionais com início e término reais.
- Motor determinístico de disponibilidade.
- Simulador interno de agenda antes das integrações.
- Integração real com um calendário Google espelho por estabelecimento.
- WhatsApp Cloud API oficial restrita inicialmente ao número da Duda.
- Atendimento por texto e áudio.
- Cadastro progressivo da cliente.
- Proposta, confirmação, cancelamento e remarcação.
- Reserva temporária para impedir disputa pelo mesmo horário.
- Transferência para atendimento humano.
- Pausa por conversa e pausa global de emergência.
- Mensagem final configurável.
- Logs correlacionados, idempotência e auditoria.
- Métricas técnicas e operacionais do piloto.
- Testes específicos dos dois segmentos e teste de isolamento entre tenants.

### 4.2 Explicitamente fora

- Cobrança de sinal das clientes.
- Mercado Pago, Stripe ou outro provedor de pagamento.
- Estado `AGUARDANDO_PAGAMENTO`.
- Campanhas promocionais e disparos em massa.
- CRM avançado e segmentação comercial.
- Billing e cobrança recorrente do SaaS.
- Landing page, checkout e anúncios patrocinados.
- Aplicativo móvel nativo.
- Embedded Signup como fluxo autônomo de onboarding comercial.
- Agente do proprietário com ações coletivas.
- Classificação de fotos com decisão financeira totalmente automática.
- Migração ou leitura integral do histórico anterior do WhatsApp.
- Liberação para todas as clientes dos estabelecimentos antes dos gates de QA e segurança.

Esses itens poderão existir no roadmap futuro, mas não podem aumentar o prazo nem ser tratados como dependência do piloto.

## 5. Atores

| Ator                    | Responsabilidade no piloto                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------- |
| Duda                    | Fundadora, administradora, testadora e única cliente permitida inicialmente no WhatsApp         |
| William                 | Proprietário do primeiro estabelecimento e responsável por validar regras operacionais do salão |
| Jack                    | Proprietária do segundo estabelecimento e responsável por validar as regras do studio           |
| Profissional            | Executa uma ou mais etapas de serviços conforme habilidade e turno                              |
| Assistente              | Executa ou acompanha etapas específicas, sem ser presumida como disponível                      |
| Cliente simulada        | Persona representada pela Duda durante os testes                                                |
| Agente de IA            | Interpreta linguagem, extrai intenção e redige respostas; não decide disponibilidade            |
| Motor de agenda         | Calcula e valida horários, profissionais, recursos e restrições                                 |
| Administrador do tenant | Configura o estabelecimento e autoriza integrações                                              |
| Atendimento humano      | Assume conversas ambíguas, excepcionais ou bloqueadas                                           |

Clientes finais do estabelecimento não são usuários autenticados do painel.

## 6. Regra de prontidão para agendar

Cada tenant terá um estado de prontidão de agendamento. O sistema só poderá consultar ou propor horários quando todos os itens obrigatórios estiverem válidos.

### Checklist mínimo de prontidão

- Fuso horário e unidade definidos.
- Expediente e término máximo definidos para os dias atendidos.
- Pausas, almoço e bloqueios relevantes definidos.
- Ao menos um profissional ativo.
- Turnos ou regras de disponibilidade válidos para os profissionais utilizados.
- Serviço ativo, vendável e com duração resolvível.
- Todas as etapas do serviço ativas, ordenadas e com duração válida.
- Ao menos uma pessoa apta por etapa que exige profissional.
- Recursos obrigatórios cadastrados e disponíveis.
- Dependências e regras de bloqueio/liberação definidas.
- Variações e perguntas obrigatórias definidas quando alterarem duração ou preço.
- Preparos obrigatórios vinculados e configurados.
- Calendário espelho conectado e sincronizado.
- Política de sinal explicitamente configurada como `desativada`.
- Mensagem final configurada.
- Canal em modo de teste e allowlist contendo somente o número autorizado.

Se algum item obrigatório estiver ausente, o sistema deve bloquear a oferta de horários, apontar a configuração faltante ao administrador e encaminhar a conversa para humano quando necessário. A LLM não pode completar lacunas por suposição.

## 7. Regras centrais do agendamento

1. Serviço composto é uma unidade vendável formada por etapas; lavagem, pausa e chapinha não viram serviços isolados apenas para facilitar o código.
2. Cada etapa informa duração, participantes aptos, recursos, dependências e se bloqueia ou libera cada participante.
3. A pausa de produto pode liberar um profissional e continuar ocupando cadeira, cliente ou outro recurso.
4. O horário de fechamento é o término máximo. Um procedimento que terminaria depois dele é inválido.
5. Profissional ou assistente ocasional só participa quando existir turno confirmado com início e fim reais.
6. Cor de evento não comprova disponibilidade.
7. Almoço, pausas, preparos, bloqueios, eventos externos e exceções participam do cálculo.
8. Exceção fora do expediente só vale quando registrada e aprovada segundo a regra configurada.
9. O motor deve validar a linha do tempo completa antes de devolver uma opção à LLM.
10. A escolha da cliente cria uma reserva temporária; a confirmação final ocorre de forma transacional.
11. Dois pedidos concorrentes não podem confirmar o mesmo profissional ou recurso no mesmo intervalo.
12. Remarcação oferece alternativas e aguarda escolha; não impõe um novo horário.

## 8. Interpretação correta de “uma única agenda”

No piloto, cada estabelecimento conecta um calendário Google espelho principal. Isso simplifica a integração externa, mas não elimina a modelagem interna de capacidade.

O banco continuará distinguindo:

- profissional e assistente;
- turno individual;
- habilidade por etapa;
- recurso compartilhado;
- reserva de etapa;
- ocupação externa;
- exceção e bloqueio.

Os eventos sincronizados com o calendário espelho deverão carregar metadados internos suficientes para correlação e idempotência. A arquitetura deve permitir calendários separados no futuro sem reescrever o domínio.

## 9. Fluxo funcional do piloto

1. A Duda envia texto ou áudio pelo número autorizado.
2. O webhook recebe, autentica e deduplica o evento.
3. O sistema identifica tenant, conversa e cliente simulada.
4. A LLM extrai intenção e campos usando saída estruturada.
5. O orquestrador verifica quais dados ainda bloqueiam duração, preço ou agenda.
6. O agente faz apenas uma pergunta objetiva por vez quando necessário.
7. O motor monta o serviço e suas etapas.
8. O motor consulta configuração interna e ocupações sincronizadas do calendário espelho.
9. O motor calcula e classifica somente opções válidas.
10. A LLM redige a resposta usando exclusivamente as opções aprovadas.
11. A escolha cria uma reserva temporária.
12. A confirmação grava agendamento e etapas em transação.
13. Um evento é criado ou atualizado no calendário espelho com idempotência.
14. O sistema envia mensagem final e registra auditoria e métricas.

## 10. Estados do agendamento

Fluxo principal:

```text
SOLICITACAO
→ COLETA_DE_DADOS
→ BUSCA_DE_HORARIOS
→ HORARIO_PROPOSTO
→ RESERVA_TEMPORARIA
→ CONFIRMADO
→ SINCRONIZACAO_PENDENTE
→ SINCRONIZADO
```

Estados alternativos:

```text
EXPIRADO
CANCELADO
REAGENDAMENTO_PENDENTE
FALHA_DE_INTEGRACAO
ATENDIMENTO_HUMANO
```

Não existe estado de pagamento neste piloto.

## 11. Requisitos não funcionais mínimos

- **Isolamento:** nenhum usuário ou processo de um tenant acessa dados de outro tenant.
- **Consistência:** confirmações concorrentes são protegidas por transação e restrições no banco.
- **Idempotência:** reprocessar webhook não duplica conversa, mensagem, evento ou agendamento.
- **Auditabilidade:** toda decisão relevante registra versão da configuração, entradas, regras e resultado.
- **Falha segura:** indisponibilidade do Google, WhatsApp ou LLM não produz confirmação falsa.
- **Privacidade:** fotos, áudios e mensagens têm acesso restrito, retenção definida e conteúdo mínimo em logs.
- **Recuperação:** falhas de sincronização entram em fila de repetição e reconciliação.
- **Observabilidade:** erros, latência, filas, sincronizações e conflitos geram métricas e alertas.
- **Usabilidade:** cadastros permitem criar, editar, inativar e excluir com confirmação adequada.
- **Evolução:** regras específicas dos pilotos são dados configuráveis, não condicionais por nome de cliente.

## 12. Métricas do piloto

- Solicitações de agendamento iniciadas.
- Solicitações bloqueadas por configuração incompleta.
- Horários candidatos avaliados e rejeitados pelo motor.
- Opções oferecidas.
- Propostas aceitas.
- Agendamentos confirmados.
- Conversas transferidas para humano.
- Conflitos gerados, com meta obrigatória de zero.
- Diferença entre duração prevista e duração real informada.
- Latência por etapa do fluxo.
- Falhas e atrasos de sincronização.
- Webhooks duplicados recebidos e deduplicados.
- Custo de IA por conversa concluída.
- Mensagens necessárias por agendamento.
- Cancelamentos e remarcações.
- Erros por versão da configuração.

CAC, LTV, preço e retorno financeiro não são métricas de liberação do piloto. Ainda não há dados reais que sustentem projeções comerciais.

## 13. Gates e critérios de saída

### Gate A — Escopo aprovado

- Este documento aprovado explicitamente pela Duda.
- Itens fora do piloto aceitos sem inclusão paralela.
- William e Jack confirmados como referências dos dois tenants.
- Sinal confirmado como desativado para ambos.
- Agenda única e calendário espelho confirmados.

### Gate B — Configuração pronta

- Cadastros reais dos dois estabelecimentos completos.
- Checklist de prontidão aprovado pelo sistema.
- Nenhum valor indispensável depende de texto hardcoded no prompt.
- Configuração recarregada do banco sem perda de dados.
- Alterações de cadastro produzem efeito verificável no motor.

### Gate C — Motor aprovado no simulador

- Pelo menos 40 cenários do William executados.
- Pelo menos 20 cenários da Jack executados.
- Cenários de concorrência, exceção, almoço, etapas, recursos e turnos ocasionais executados.
- Zero horário inválido oferecido.
- Zero dupla reserva confirmada.
- Tentativa de acesso cruzado entre tenants bloqueada.

### Gate D — Integrações controladas aprovadas

- Calendário espelho sincronizado nos dois sentidos e reconciliado.
- Eventos duplicados não geram agendamentos duplicados.
- WhatsApp aceita somente o número da Duda.
- Texto e áudio percorrem o fluxo completo.
- Falhas do Google, WhatsApp e LLM terminam de forma segura e auditável.

### Gate E — Piloto humano assistido

- Duda executa todos os cenários prioritários como cliente simulada.
- William valida a representação de sua operação.
- Jack valida a representação de sua operação.
- QA e Segurança aprovam evidências.
- Somente após aprovação explícita poderá ser planejada a conexão de agenda real ou a liberação limitada a clientes reais.

## 14. Riscos críticos e tratamento

| Risco                                            | Consequência                                | Tratamento obrigatório                           |
| ------------------------------------------------ | ------------------------------------------- | ------------------------------------------------ |
| Configuração incompleta                          | Horário impossível ou preço/duração errados | Gate de prontidão bloqueante                     |
| Serviço composto simplificado                    | Conflitos ocultos entre etapas              | Linha do tempo por etapa                         |
| Agenda única tratada como capacidade única       | Sobreposição de pessoas e recursos          | Modelo interno separado da integração externa    |
| LLM decidindo disponibilidade                    | Invenção de horário                         | Motor determinístico como única fonte de opções  |
| Eventos manuais não sincronizados                | Dupla reserva                               | Sync incremental e reconciliação                 |
| Webhook repetido                                 | Mensagem ou evento duplicado                | Inbox idempotente e chave externa única          |
| Liberação precoce para clientes                  | Dano operacional e reputacional             | Allowlist e gates de QA/Segurança                |
| Regra específica codificada para William ou Jack | Produto impossível de escalar               | Transformar caso em configuração por tenant      |
| Escopo voltar a incluir pagamento                | Atraso sem validar o núcleo                 | Sinal fora do piloto e feature flag futura       |
| Projeções financeiras tratadas como fatos        | Preço e investimento mal decididos          | Instrumentar uso real antes da decisão comercial |

## 15. Pendências que não bloqueiam este escopo, mas bloqueiam os requisitos detalhados

### William

- Cadastro definitivo de serviços, variações, preços e durações.
- Decomposição de cada serviço composto em etapas.
- Quem pode executar e substituir cada etapa.
- Recursos ocupados e regras de liberação durante pausas.
- Expediente, almoço, tolerâncias e exceções por dia.
- Regras de preparos, incluindo teste de mechas.
- Critérios de comprimento, volume, textura e condição do cabelo.

### Jack

- Serviços definitivos, durações, preços e variações.
- Quantidade e função das profissionais ativas no piloto.
- Habilidades, turnos, folgas, pausas e comissionamento quando relevante ao produto.
- Recursos exclusivos ou compartilhados.
- Expediente, almoço, tolerâncias e exceções.
- Regras que diferenciam cílios, unhas e outros serviços.

### Integrações e operação

- Conta Google que hospedará cada calendário espelho.
- Convenção de eventos e permissões OAuth.
- Número e conta Meta usados no ambiente de teste.
- Mensagens finais e gatilhos de transferência humana.
- Prazos de retenção para texto, áudio, imagem e logs.
- Pessoas autorizadas a administrar cada tenant.

Essas respostas serão coletadas de forma objetiva no documento de requisitos e no formulário de configuração. Elas não justificam voltar a ampliar o escopo.

## 16. Situação dos artefatos anteriores

Este documento passa a ser a baseline do piloto após aprovação. Em caso de conflito:

1. Decisões aprovadas neste escopo prevalecem.
2. Requisitos e decisões arquiteturais versionadas posteriores podem detalhá-lo sem ampliar o piloto silenciosamente.
3. O dossiê e o protótipo permanecem como histórico e referência visual, não como prova de implementação.
4. O roadmap anterior é corrigido: sinal/pagamento saem do piloto; serviços compostos entram antes de oferecer horários; multiempresa nasce desde o banco.
5. O relatório de créditos permanece uma projeção não medida e não define orçamento.
6. O relatório financeiro permanece um conjunto de hipóteses não validadas e não define preço, break-even ou canal de aquisição.

## 17. Próximo artefato autorizado após aprovação

Após a aprovação explícita deste escopo, o próximo documento será:

`requisitos-piloto-v1.md`

Ele deverá conter:

- requisitos funcionais e não funcionais numerados;
- regras de negócio e precedências;
- critérios de aceite verificáveis;
- casos de uso e falhas seguras;
- matriz de rastreabilidade;
- perguntas mínimas de configuração de William e Jack;
- evidência exigida para cada requisito.

Modelagem do banco, contratos de API e código continuam bloqueados até os requisitos determinantes serem aprovados.

## 18. Registro das decisões da fundadora

Em 03 de agosto de 2026, a fundadora confirmou:

- “As duas opções são a Jack.”
- “Uma única agenda.”
- “Sim” para o uso de calendário espelho nos primeiros testes.

Essas respostas resolvem as três decisões que bloqueavam a formalização deste escopo.
