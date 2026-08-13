# Backlog de Produção — SaaS Completo de Agente de IA para Beleza

**Status:** plano de execução; não é cronograma nem promessa de data.  
**Princípio:** o produto comercial alvo é completo. Os gates abaixo não reduzem esse alvo; impedem que uma capacidade perigosa seja vendida antes de existir evidência operacional.

## 1. Sequência inevitável de dependências

Não há um caminho técnico honesto que comece por “campanhas inteligentes” ou “agente que altera horários” antes de histórico executado, consentimento, agenda determinística, outbox e auditoria. Pular isso não acelera; só desloca o erro para uma cliente real, onde custa reputação, dados e dinheiro.

| Gate | Entrega verificável | Depende de | Bloqueia se faltar |
|---|---|---|---|
| G0 | Base de segurança, papéis, RLS, logs, secrets, correlação e CI | estado atual | qualquer venda com dado de cliente |
| G1 | Catálogo técnico versionado, equipe, recursos e matriz de preço/duração | G0 | orçamento, agenda e agente técnico confiáveis |
| G2 | Motor de agenda, cotação, reserva concorrente, política e execução de atendimento | G1 | confirmação real, “último procedimento” e recorrência |
| G3 | WhatsApp oficial, inbox, projeção CRM, consentimento e atendimento humano | G0 | atendimento real e captação confiável de histórico |
| G4 | CRM técnico, histórico de execução, retorno, promoções e segmentação explicável | G2 + G3 | campanhas de retorno e personalização segura |
| G5 | Campanhas governadas, template sync, snapshot, aprovação, outbox e status | G3 + G4 | qualquer disparo de marketing |
| G6 | Agente conversacional com ferramentas de leitura, agenda e handoff | G1 + G2 + G3 | promessa de agente autônomo de atendimento |
| G7 | Agente da proprietária com planos, confirmação e auditoria | G2 + G4 + G5 + G6 | alterações coletivas e ações externas por IA |
| G8 | Visão/STT, imagem consentida, confiança e revisão humana | G0 + G1 + G3 | orçamento/decisão baseada em foto ou áudio |
| G9 | QA de ponta a ponta, segurança/LGPD, carga, observabilidade, suporte e readiness comercial | G0–G8 | venda pública do pacote completo |

## 2. Backlog por área de produto

### 2.1 Fundação, segurança e operação

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| FND-01 | Consolidar migrations versionadas e inventário de tabelas existentes | Schema aplicado e documentação de proveniência por tabela |
| FND-02 | Formalizar autorização por `site_identities`/papéis e RLS de todo domínio novo | Testes negativos entre tenants e entre papéis |
| FND-03 | Padronizar `correlation_id`, `idempotency_key`, `audit_event` e erros de domínio | Uma operação é rastreável ponta a ponta em log/auditoria |
| FND-04 | Configurar monitoramento, alertas, DLQ e execução segura de jobs | Falha induzida gera alerta, DLQ e replay idempotente |
| FND-05 | Definir LGPD por tipo de dado, consentimento, retenção, exportação e eliminação | Fluxo de titular é testado com mídia e mensagens |

### 2.2 Catálogo técnico e configurador de cabelo

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| CAT-01 | Entidades `service`, versão, etapa, variação, recurso, habilidade e pré-requisito | Migração, RLS, constraints e testes de integridade |
| CAT-02 | Editor de serviço simples/composto com ordenação e condições | Tela salva, recarrega e mostra versão publicada |
| CAT-03 | Biblioteca de tipos de etapa e templates de corte, tratamento, cor e textura | Tenant cria/adapta template sem receber receita fixa de produto |
| CAT-04 | Matriz de preço/duração com explicação determinística | Cenários de variação retornam preço/duração ou revisão necessária |
| CAT-05 | Controle de produto, teste, segurança e revisão profissional para químicas | Serviço é bloqueado quando o pré-requisito obrigatório falha |
| CAT-06 | Perfil descritivo de cabelo e ilustrações educativas/licenciadas | Seleção acessível; imagem não gera decisão automática de preço/química |

### 2.3 Agenda, execução e pagamento

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| AGD-01 | Solver por etapas, profissionais, recursos, pausas, turnos e fechamento | Matriz de cenários rejeita todos os conflitos conhecidos |
| AGD-02 | Cotação, hold e reserva atômica | Teste concorrente não gera dupla reserva |
| AGD-03 | Estados de cancelamento, remarcação, atraso, no-show e política | Auditoria indica regra/precedência aplicada |
| AGD-04 | Registro de execução e duração real por etapa | CRM deriva histórico somente de atendimento concluído |
| AGD-05 | Google Calendar incremental, bidirecional e reconciliável | Evento duplicado/alterado não cria loop ou conflito silencioso |
| AGD-06 | Sinal por política e integração de pagamento | Confirmação depende de evento verificável, não de texto da cliente |

### 2.4 WhatsApp e inbox

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| WA-01 | Embedded Signup, mapeamento WABA/número e gestão de segredo por tenant | Um canal só roteia ao tenant que o configurou |
| WA-02 | Webhook validado, inbox event e fila de projeção | Reentrega do provedor não duplica efeito |
| WA-03 | Projetor de contato, canal, conversa, mensagem e status | Inbox mostra eventos normalizados e tenant isolado |
| WA-04 | Inbox operacional com assunção humana, pausa e emergência | Pausa bloqueia resposta do agente verificadamente |
| WA-05 | Mídia/áudio assíncronos e falhas tratadas | Erro de processamento não perde a mensagem nem inventa transcrição |
| WA-06 | Sync de templates, qualidade e categoria | Template inválido é bloqueado antes do outbox |

### 2.5 CRM, retorno e campanhas

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| CRM-01 | Timeline unificada de cliente e busca com acesso por papel | Linha do tempo explica origem e data de cada informação |
| CRM-02 | Consentimento, preferência, opt-out e limites por finalidade/canal | Opt-out bloqueia envio posterior em teste de worker |
| CRM-03 | Regra de retorno pós-execução e elegibilidade explicável | Cliente entra/sai com motivos corretos e sem texto heurístico |
| CRM-04 | Promoções versionadas e aplicáveis à cotação elegível | Benefício não é aplicado fora de vigência/condição |
| CMP-01 | Segmentador e preview de público congelado | Proprietária vê incluídas/excluídas e motivos |
| CMP-02 | Aprovação humana com versão e invalidação por mudança | Mudança no snapshot invalida aprovação anterior |
| CMP-03 | Dispatch via outbox, idempotência, retry e status Meta | Uma destinatária recebe no máximo um envio por campanha/chave |
| CMP-04 | Relatório de entrega, falha, leitura e descadastro | Dashboard concilia status externo e decisão local |

### 2.6 Agentes e inteligência

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| AI-01 | Taxonomia de intenção, resumo de sessão e contexto mínimo por tenant | Teste de prompt cross-tenant não recupera dado externo |
| AI-02 | Gateway de ferramentas com schemas e políticas | Ação fora da allowlist não é executável pelo modelo |
| AI-03 | Ferramentas de leitura: catálogo, cotação, agenda, histórico e política | Resposta exibe fatos do motor e pergunta única quando há bloqueio |
| AI-04 | Ferramentas de escrita: hold, solicitação de agenda e atualização de rascunho | Nenhuma mutação crítica ocorre sem estado/política correspondente |
| AI-05 | Handoff e explicação de incerteza para foto/química | Baixa confiança abre tarefa humana e evita promessa |
| AI-06 | Agente da proprietária com plano, impacto e confirmação | Ação coletiva só cria outbox após confirmação versionada |
| AI-07 | Avaliação contínua de qualidade, segurança e custo de modelos | Casos dourados, regressão e dashboard de custo por fluxo |

### 2.7 Go-live e operação comercial

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| REL-01 | Matriz QA por segmento: salão, cílios e manicure | Evidências de visível, editável, persistente, aplicado, falha e teste |
| REL-02 | Auditoria de segurança/LGPD e threat model | Riscos críticos mitigados ou bloqueados formalmente |
| REL-03 | Runbooks de incidente, suporte, onboarding e desativação de tenant | Operadora executa simulação de incidente e recuperação |
| REL-04 | Observabilidade de produto, integração e IA | Dashboards e alertas operacionais ativos |
| REL-05 | Piloto controlado com dados reais autorizados e aprovação de QA | Métricas de uso, erro, abandono e operação humana registradas |

## 3. Critérios de priorização

| Prioridade | Regra |
|---|---|
| P0 | Segurança, isolamento, dados e requisito sem o qual uma ação externa pode causar dano ou vazamento. |
| P1 | Capacidade que cria valor direto de agendamento/atendimento com evidência operacional. |
| P2 | Capacidade que aumenta automação, personalização ou escala depois que P0/P1 estão estáveis. |
| P3 | Conveniência visual, automação opcional ou integração de nicho sem dependência direta de segurança/receita. |

O primeiro bloco de implementação recomendado é **FND-01 a FND-05, CAT-01 a CAT-05, AGD-01/02/04, WA-01 a WA-04 e CRM-01/02**. Ele não entrega “tudo”, mas constrói as fundações que tornam o restante possível. Tentar começar por foto, campanha ou chat proprietário antes desse bloco é desperdício: produz demo visual sem consequência confiável.

## 4. Investimento e métricas: o que é conhecido e o que não é

Não há dados medidos de cliente pagante, volume de mensagens, sessões de IA, fotos, chamadas de calendário, provedor de pagamentos escolhido ou preço comercial. Portanto, qualquer orçamento total, prazo de lucro, CAC, LTV ou custo por cliente agora seria ficção.

| Variável de investimento | Estado | Como medir antes de decidir preço/venda |
|---|---|---|
| Tempo de engenharia e QA | Premissa ainda não levantada | registrar horas por item do backlog e retrabalho por integração |
| Infraestrutura | Não consolidada | custo mensal de Supabase, Vercel, storage, filas e observabilidade por tenant |
| WhatsApp | Dependente de país, categoria/template e volume | ledger de mensagens por tipo, status e unidade |
| IA/STT/visão | Dependente de modelo, mídia e política de retenção | tokens, duração de áudio, imagens, falhas e custo por conversa |
| Suporte humano | Não medido | handoffs, duração, causa e resolução por fluxo |

As métricas devem nascer junto com cada módulo: conversas resolvidas/handoff, cotação→reserva, reserva→execução, cancelamento/no-show, retorno elegível→campanha aprovada→agendamento, opt-out, erro de integração, confiança visual, erro de agenda e custo de IA por conversa. Isso permite preço posterior baseado em uso real, não em entusiasmo.

## 5. Riscos que merecem decisão explícita

| Risco | Consequência | Mitigação exigida |
|---|---|---|
| “Tudo configurável” sem modelo | Interface inoperável e regra impossível de testar | templates, limites de extensibilidade, versão e revisão |
| IA decide química/preço | dano à cliente e responsabilidade do negócio | catálogo aprovado, perguntas bloqueantes e escalonamento humano |
| CRM sem execução real | campanhas erradas e perda de confiança | derivar retorno de `COMPLETED` com versão/histórico |
| Campanha sem governança | bloqueio Meta, LGPD e reputação | consentimento, template, frequência, snapshot, aprovação/outbox |
| Foto como fato | discriminação, erro técnico e preço injusto | consentimento, confiança e revisão humana |
| Agente com acesso direto | mutação acidental/ataque por prompt | gateway, schemas, confirmação, auditoria e menor privilégio |
| Escalar antes de QA | suporte manual caótico e churn | piloto controlado, métricas e runbooks antes de aquisição |
