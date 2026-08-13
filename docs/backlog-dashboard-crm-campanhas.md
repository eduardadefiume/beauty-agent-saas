# Backlog fatiado — Dashboard multiempresa, CRM Inbox e campanhas

**Artefato:** backlog de implementação e critérios verificáveis  
**Base:** requisitos, modelo de domínio e arquitetura aprovados para detalhamento  
**Estado:** documentado. Nenhum item abaixo está implementado, testado integralmente ou conectado em produção, salvo quando indicado como componente pré-existente.

## Objetivo do corte

O primeiro corte operacional entrega um dashboard **genérico por tenant**, com inbox WhatsApp como CRM inicial e a capacidade de realizar **uma campanha real controlada no tenant piloto**. O configurador permanece na raiz. CRM de perfil/histórico avançado, campanhas recorrentes, automações de nutrição, IA respondendo clientes e escala para vários pilotos ficam fora deste corte, mas continuam no escopo do produto.

> O corte não é um protótipo visual. Ele só é aceito quando cada consulta, fila, worker e envio possui evidência de isolamento, idempotência e auditoria.

## Ordem de implementação

| Ordem | ID | Fatia | Resultado observável | Dependência |
|---:|---|---|---|---|
| 1 | DB-01 | Contexto multiempresa | O dashboard identifica e apresenta somente o negócio do tenant autenticado. | Membership/tenancy existente. |
| 2 | DB-02 | Navegação configurador → operação | A raiz mantém o configurador; menu/CTA abre `/dashboard` do tenant correto. | DB-01. |
| 3 | DB-03 | Segurança de acesso | RLS e RPCs negam leitura/escrita cross-tenant com evidência automatizada. | DB-01. |
| 4 | CRM-01 | Modelo CRM e migrações | Contatos, canais, conversas, mensagens, consentimentos e auditoria existem por `tenant_id`. | DB-03. |
| 5 | INB-01 | Ingestão idempotente | Webhook persiste evento, reconhece duplicidade e responde sem projetar UI no request síncrono. | CRM-01; webhook pré-existente. |
| 6 | INB-02 | Fila e projeção de inbox | Evento de WhatsApp vira conversa/mensagem materializada pelo worker. | INB-01; cron/fila. |
| 7 | INB-03 | Interface de inbox | Tenant vê conversas, mensagens, status e estados vazios apenas do próprio negócio. | INB-02. |
| 8 | CMP-01 | Consentimento e templates | Opt-in/out e templates sincronizados bloqueiam público inelegível. | CRM-01. |
| 9 | CMP-02 | Rascunho e prévia | Operador cria rascunho e recebe elegíveis/excluídos antes de qualquer envio. | CMP-01. |
| 10 | CMP-03 | Aprovação e audiência congelada | Aprovação humana registra responsável, momento e destinatários imutáveis. | CMP-02. |
| 11 | CMP-04 | Envio real controlado | Worker envia lote limitado, salva provider ID e recebe status pelo webhook. | CMP-03; Meta configurada. |
| 12 | CMP-05 | Kill switch e auditoria | Suspensão por tenant/campanha interrompe novos envios; toda transição é auditável. | CMP-04. |
| 13 | AGD-01 | Vínculo com agenda | Agendamento passa a referenciar CRM contact opcional sem quebrar dados existentes. | CRM-01. |

## Itens de implementação detalhados

### DB-01 — Contexto multiempresa no dashboard

**História.** Como usuário de uma empresa, quero que a operação use a empresa à qual pertenço para nunca acessar dados do cliente errado.

| Critério de aceite | Evidência mínima |
|---|---|
| `/dashboard` resolve a membership a partir da sessão no servidor. | Teste de integração autenticado. |
| Título, identidade e contadores vêm do tenant resolvido. | Captura em dois tenants de teste distintos. |
| Um `tenant_id` arbitrário enviado pela UI não amplia acesso. | Teste negativo retornando `403`/zero linhas. |
| Nenhuma referência fixa a “William” permanece no componente, consulta ou fallback. | Busca de código e teste de renderização por fixture. |

### DB-02 — Navegação entre configurador e operação

**História.** Como proprietário, quero configurar o negócio na raiz e entrar na operação sem trocar de empresa.

| Critério de aceite | Evidência mínima |
|---|---|
| Após login e reset, o usuário retorna ao configurador `/`. | Teste E2E/manual documentado. |
| Existe entrada visível “Operação” que abre `/dashboard`. | Captura desktop e mobile. |
| Retorno ao configurador mantém a mesma empresa ativa. | Teste com duas memberships. |

### CRM-01 — Migração de CRM e consentimento

**História.** Como sistema, quero persistir identidade de contato, canal, conversa e consentimento separadamente para atender a operação e a privacidade.

| Critério de aceite | Evidência mínima |
|---|---|
| Todas as novas entidades têm `tenant_id NOT NULL`, índices de tenant e RLS habilitado. | SQL de migração + teste de política. |
| `crm_contacts` não duplica contatos pelo mesmo canal normalizado dentro do tenant. | Restrição e teste de UPSERT. |
| Cada mudança de consentimento registra fonte, momento e ator/origem. | Consulta de auditoria. |
| Revogação de consentimento é imediata e não apagada por nova sincronização. | Teste de estado. |

### INB-01 a INB-03 — Inbox WhatsApp

| Critério transversal | Evidência mínima |
|---|---|
| Replay do mesmo webhook não duplica `inbox_event`, `conversation` ou `message`. | Teste com payload repetido. |
| Webhook responde sem aguardar projeção de CRM. | Log de latência e job enfileirado. |
| Worker consome lote com visibility/lock e arquiva erro irrecuperável. | Teste de falha e inspeção de fila. |
| UI não exibe conteúdo de outra empresa. | Teste cross-tenant negativo e captura com dois tenants. |
| Status de Meta atualiza mensagem existente pelo `provider_message_id`. | Fixture de webhook de status. |

### CMP-01 a CMP-05 — Campanha real governada

| Critério transversal | Evidência mínima |
|---|---|
| Prévia inclui somente consentimentos ativos, canal disponível e template elegível. | Contagens elegível/excluído e motivos. |
| Rascunho, prévia e aprovação não executam chamada de envio. | Teste de ausência de `outbound_delivery` enviada. |
| Aprovação congela audiência, template e variáveis de versão. | Hash/audit e tentativa de mudança bloqueada. |
| Cada destinatário tem chave idempotente, estado e provider ID únicos. | Índice + teste de retry. |
| Worker revalida consentimento imediatamente antes de enviar. | Teste de opt-out depois da aprovação. |
| Conexão/template com falha pausa campanha e exige ação humana. | Teste de erro Meta simulado. |
| Kill switch impede que itens pendentes sejam enviados. | Teste de cancelamento durante fila. |
| Primeiro envio real usa uma campanha, um tenant, público consentido, template aprovado e aprovação nomeada. | Auditoria, registros de entrega e status webhook. |

## Componentes pré-existentes e tratamento

| Componente | Estado conhecido | Ação no backlog |
|---|---|---|
| `whatsapp-webhook` | Implementado como porta de entrada com assinatura e idempotência de evento. | Preservar e integrar à fila; testar novamente com projeção. |
| Tenancy/membership base | Existe em migração `fv01_base_tenancy`. | Reusar; ampliar testes e políticas apenas onde necessário. |
| Motor de agenda | Existe na migração do engine de agendamento. | Vínculo opcional em AGD-01, sem reescrita. |
| Dashboard com composição editorial | Existe visualmente, mas está específico de William. | Generalizar em DB-01/DB-02, não descartar a direção visual. |

## Fora do corte inicial, porém dentro do produto

| Módulo | Estado | Condição para iniciar |
|---|---|---|
| Perfil CRM completo e histórico unificado | Planejado. | Inbox e contato canônico estáveis. |
| Segmentação avançada por comportamento/agenda | Planejado. | Base de consentimento e dados de agenda vinculada. |
| Campanhas recorrentes e jornadas automáticas | Planejado. | Primeiro envio auditado, limites e kill switch comprovados. |
| Agente do proprietário | Planejado. | Dados operacionais confiáveis e permissões granulares. |
| IA para resposta ao cliente | Planejado. | Política de handoff, consentimento, logs e qualidade aprovados. |
| Outros canais de comunicação | Planejado. | Contrato de canal e modelo de consentimento reutilizáveis. |

## Gates de liberação

| Gate | Bloqueia | Prova exigida |
|---|---|---|
| G1 — Modelo/RLS | UI com dados reais. | Migração, políticas e testes cross-tenant. |
| G2 — Inbox | Exibição de conversas de produção. | Replay idempotente, fila e projeção de teste. |
| G3 — Consentimento | Prévia de campanha. | Registro de opt-in/opt-out e exclusões visíveis. |
| G4 — Meta | Qualquer envio. | Conexão ativa, template aplicável/aprovado e webhook de status recebido. |
| G5 — Operação | Primeiro envio real. | Aprovação humana, kill switch, auditoria e QA de falha/retry. |
| G6 — Produção | Promoção de campanha. | Revisão de segurança/LGPD e aceite explícito da proprietária. |

## Decisão solicitada

O backlog recomenda iniciar **DB-01 → DB-03** e **CRM-01** antes de mexer na inbox visual. Isso remove a dependência de William e estabelece o isolamento que impede erros caros depois. A implementação de webhook/worker e envio só deve iniciar depois de os testes de tenant/RLS serem aprovados.
