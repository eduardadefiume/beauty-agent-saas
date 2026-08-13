# Requisitos — Inbox WhatsApp e campanhas governadas por tenant

**Artefato:** requisitos funcionais e critérios de aceite  
**Fase do trabalho:** requisitos após escopo rebaselined; modelagem e implementação pendentes  
**Decisões da proprietária:** CRM inicia por **inbox/conversas WhatsApp**; campanhas incluem **envio real controlado no piloto**.

> **Estado real:** documentado. Não implementado, não testado e não conectado em produção. O dashboard visual atualmente exibido em preview permanece específico ao William e não comprova estes módulos.

## 1. Objetivo do primeiro corte

Permitir que cada negócio autenticado consulte exclusivamente suas conversas e eventos de WhatsApp, e que um usuário autorizado execute uma campanha real de teste para um público elegível do seu próprio tenant. A campanha não pode iniciar sem consentimento, template aprovado, prévia de destinatários, aprovação humana, rastreabilidade e proteção contra repetição.

O escopo não inclui um CRM comercial completo, automação irrestrita de marketing, campanhas recorrentes, campanhas multicanal, IA autônoma disparando mensagens ou uma caixa de entrada global.

## 2. Requisitos funcionais

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-01 | O Dashboard deve resolver o `tenant_id` pelo usuário autenticado, nunca por parâmetro de URL, cache do navegador ou fallback. | Um usuário do tenant A não recebe, não encontra e não consegue inferir dados do tenant B; tentativa direta é negada e auditada. |
| RF-02 | A Inbox deve listar mensagens, eventos de entrega e conversas recebidas no WhatsApp do tenant ativo. | Após um webhook real ou payload de teste assinado aceito, a conversa e o evento aparecem apenas no tenant correto, com horário, direção e status. |
| RF-03 | A Inbox deve agrupar eventos por conversa/cliente e manter ordem cronológica. | Mensagem recebida, mensagem enviada e atualizações de status são visíveis na mesma conversa, sem duplicar evento reenviado pela Meta. |
| RF-04 | A Inbox deve expor o estado operacional de cada conversa, sem fingir resposta humana ou de IA. | A interface distingue claramente: recebida, enviada, entregue, lida, falha e aguardando atendimento; ausência de evento é exibida como estado desconhecido. |
| RF-05 | O sistema deve criar/atualizar um perfil mínimo de cliente pelo identificador WhatsApp somente no tenant correspondente. | O perfil tem identificador de canal, nome quando recebido, histórico de mensagens e consentimentos; não cria cópia em outro tenant. |
| RF-06 | O sistema deve persistir consentimento de campanha por cliente, canal e tenant, com data, origem, texto/política aceita e estado de revogação. | Um cliente sem consentimento ativo não entra em nenhuma prévia de campanha; revogação o exclui de envios futuros. |
| RF-07 | O usuário deve montar uma campanha usando somente template de WhatsApp do tenant que esteja elegível para envio. | A seleção bloqueia template inexistente, de outro tenant, não aprovado, pausado ou desabilitado. Templates fora da janela de atendimento exigem estado `APPROVED`, conforme a documentação oficial da Meta.[^templates] |
| RF-08 | Antes de enviar, o Dashboard deve gerar uma prévia congelada da audiência elegível e explicar cada inclusão/exclusão. | A prévia mostra quantidade, identificadores minimizados, motivo de elegibilidade, exclusões por descadastro, falta de consentimento, frequência ou dado inválido. |
| RF-09 | Uma campanha precisa de aprovação humana explícita antes de qualquer envio. | O botão de envio só habilita para usuário autorizado após confirmação explícita; a aprovação salva autor, instante, tenant, template, versão da prévia e quantidade autorizada. |
| RF-10 | O envio real deve ser assíncrono, limitado e idempotente. | Cada destinatário tem uma chave de idempotência por campanha; retentativa não cria novo envio se houver aceitação anterior. Falhas ficam reprocessáveis com motivo. |
| RF-11 | A plataforma deve atualizar a campanha pelos webhooks de status da Meta. | Eventos de aceita, enviada, entregue, lida e falha são persistidos e vinculados ao item da campanha. Status “entregue” não é exibido sem webhook correspondente.[^webhooks] |
| RF-12 | O cliente deve poder se descadastrar de mensagens de campanha, e o sistema deve aplicar a revogação antes do próximo envio. | Um opt-out recebido ou registrado pelo operador marca o consentimento como revogado, registra origem/data e exclui o cliente das próximas prévias. |
| RF-13 | A plataforma deve impor limite de frequência configurável por tenant e campanha. | Ao exceder o limite, o destinatário entra em “excluído por frequência”, com explicação; não existe opção de ignorar o bloqueio na tela. |
| RF-14 | Toda ação de alto impacto deve gerar trilha de auditoria. | Criação, edição, prévia, aprovação, disparo, cancelamento, falha, opt-in e opt-out guardam autor, tenant, instante, objeto afetado e resultado. |

## 3. Regras de negócio e segurança

| ID | Regra | Tratamento obrigatório |
|---|---|---|
| RB-01 | Isolamento multiempresa | Toda leitura e escrita carrega `tenant_id` no backend; RLS deve negar ausência ou divergência de tenant. |
| RB-02 | Integridade do webhook | O receptor valida assinatura/segredo configurado, registra o payload necessário para reprocessamento e retorna resposta adequada sem expor dados pessoais em logs. |
| RB-03 | Duplicidade de webhook | Eventos de entrada têm chave única de origem. A Meta pode reenviar notificações durante até sete dias quando o endpoint não recebe `200`; o processamento deve ser idempotente.[^webhooks] |
| RB-04 | Janela de atendimento | Fora da janela de atendimento, o envio usa template válido. O sistema não oferece texto livre como substituto de template. |
| RB-05 | Campanha controlada | No piloto, o primeiro envio possui audiência pequena e explicitamente aprovada; não há agendamento recorrente nem envio em massa automático. |
| RB-06 | Falha segura | Token ausente/expirado, template inválido, webhook não confirmado ou consentimento ausente impedem o envio e preservam o diagnóstico. |
| RB-07 | Minimização | A lista de prévia mostra dados suficientes para validar a audiência, evitando expor conteúdo completo de conversas ou dados irrelevantes. |

## 4. Fluxos de uso

### UC-01 — Consultar inbox do próprio negócio

1. Proprietário autenticado entra no configurador da raiz e acessa `Dashboard operacional`.
2. O backend resolve o tenant autorizado e carrega apenas conversas/eventos daquele tenant.
3. O proprietário abre uma conversa e consulta mensagens e estados conhecidos.
4. O sistema não mostra conversas de outro negócio nem substitui dados ausentes por dados do William.

### UC-02 — Criar e executar campanha real controlada

1. Usuário autorizado seleciona template aprovado do próprio tenant.
2. O sistema calcula audiência com regras de consentimento, descadastro e frequência.
3. Usuário revisa a prévia, os excluídos e seus motivos.
4. Usuário aprova explicitamente a versão congelada da audiência.
5. A fila envia cada item de modo idempotente, dentro do limite configurado.
6. O sistema atualiza resultados exclusivamente a partir da resposta de envio e dos webhooks recebidos.
7. O usuário acompanha pendentes, enviados, entregues, lidos e falhos, sem inferir sucesso quando não há evidência.

### UC-03 — Revogar consentimento

1. Cliente pede descadastro via canal suportado ou operador registra a solicitação.
2. O sistema revoga o consentimento de campanha no tenant correto e audita a origem.
3. A próxima prévia exclui o cliente automaticamente.

## 5. Critérios de não aceite

O módulo será reprovado se qualquer cenário abaixo ocorrer:

1. Tenant A conseguir visualizar ou disparar campanha para cliente do tenant B.
2. Campanha enviar para destinatário sem consentimento ativo ou após descadastro.
3. Envio ocorrer com template não aprovado/pausado/desabilitado.
4. Evento reenviado pela Meta duplicar mensagem, contagem ou disparo.
5. Dashboard declarar entrega/leitura sem evento comprovado.
6. Houver botão de envio sem prévia congelada e aprovação auditável.

## 6. Dependências externas e evidência mínima

| Dependência | Estado atual conhecido | Evidência exigida antes de declarar operacional |
|---|---|---|
| WhatsApp Cloud API | App Meta criado; conexão de produção não comprovada neste artefato | Token válido, número/WABA associado ao tenant, endpoint verificado e evento real recebido |
| Templates Meta | Não comprovado | Template de campanha no tenant correto com status `APPROVED` |
| Consentimento inicial | Não modelado | Registro de opt-in consentido no público do piloto |
| Fila de campanha | Não implementada | Job idempotente, logs por item, retentativa e proteção contra repetição |
| RLS multiempresa | Não revalidado para estes módulos | Teste negativo demonstrando bloqueio entre tenants |

## 7. Status verificável

| Elemento | Estado |
|---|---|
| Decisão de CRM começar por inbox | Documentado e aprovado pela proprietária |
| Decisão de primeiro envio real controlado | Documentado e aprovado pela proprietária |
| Requisitos de consentimento, aprovação e auditoria | Documentados |
| Modelo de domínio/tabelas | Pendente |
| Webhook inbox | Não comprovado neste artefato |
| Envio real de campanha | Não implementado e não testado |
| Conexão em produção | Não declarada |

[^templates]: [Meta — Template fundamentals](https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview), consultado em 13 de agosto de 2026.
[^webhooks]: [Meta — Webhooks](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview), consultado em 13 de agosto de 2026.
