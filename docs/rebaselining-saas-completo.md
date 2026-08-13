# Rebaselinação — SaaS de Agente de IA para Negócios de Beleza

**Status:** descoberta em andamento; este documento não autoriza implementação isolada.  
**Solicitação da fundadora:** 13/08/2026.  
**Fontes analisadas:** dossiê fornecido pela fundadora (`/home/ubuntu/upload/dossie-completo-agente-ia-beleza.pdf`), `docs/canonical/escopo-piloto-sem-sinal-v1.md` e `docs/canonical/modelo-dominio-configurador-v1.md`.

## Decisão solicitada e conflito encontrado

A fundadora solicitou sair da limitação exclusiva da Fase 1 e estruturar o produto completo para venda: catálogo técnico configurável de procedimentos, CRM de recorrência, campanhas governadas, agente do proprietário e inteligência conversacional.

Isso **substitui o recorte** da baseline de 03/08/2026, que excluía CRM avançado, campanhas, ações coletivas do agente, cobrança de sinal e análise visual de impacto financeiro. A substituição vale como direcionamento de produto, mas não torna os módulos implementados nem libera campanhas ou ações autônomas sem as proteções especificadas abaixo.

## Evidências preservadas do dossiê

| Tema | Requisito confirmado | Estado relatado no dossiê de 01/08/2026 |
|---|---|---|
| Multiempresa | `tenant_id`, RLS, papéis e configurações por negócio | Protótipo visual; backend multiempresa não comprovado no material de origem |
| Serviços | Serviço simples ou composto, etapas, aptidões, recursos, dependências, pausas e variações | Catálogo visível; aplicação ao motor não comprovada |
| Agenda | Solver que considera etapas, recursos, turno, almoço, exceção, preparo e término máximo | Demonstração; execução real não comprovada |
| WhatsApp | Cloud API, webhooks, inbox, templates, opt-out e pausas | Demonstração no dossiê; nenhum envio real comprovado à época |
| Clientes e imagens | Cadastro progressivo, histórico, preferências, duração real e classificação visual por confiança | Interface demonstrada; análise real não comprovada |
| CRM e campanhas | Segmentação explicável, consentimento, frequência, descadastro, template e aprovação humana | Demonstração; disparo real bloqueado |
| Agente do proprietário | Consultas imediatas; prévia, confirmação e auditoria para efeitos externos | Fluxo visual; sem agenda/WhatsApp conectados no material de origem |

## Invariantes não negociáveis

1. A LLM interpreta e redige; regras de preço, duração, elegibilidade, agenda, pagamento e autorização são determinísticas.
2. Pausa de produto pode liberar ou bloquear pessoas e recursos conforme a configuração; nunca é inferida pela LLM.
3. Um serviço composto é uma unidade vendável; lavar, pausar, enxaguar, escovar ou pranchar são etapas internas configuráveis.
4. Classificação de imagem informa hipótese com confiança, nunca confirmação clínica ou financeira automática; baixa confiança, primeira aplicação e alto impacto exigem confirmação humana.
5. Campanha só pode existir com consentimento por finalidade/canal, elegibilidade explicável, template aprovado quando exigido, limite de frequência, opt-out, prévia congelada, aprovação humana e auditoria.
6. Nenhuma ação que afete agenda, cliente ou mensagem externa é executada diretamente de texto livre do modelo.
7. Cada recurso só é declarado concluído após ser visível, editável, persistente, aplicado ao motor, seguro em falha e coberto por teste.

## Achados de pesquisa que alteram o desenho

1. A Anvisa informa que métodos comerciais como “progressiva”, “escova inteligente” ou “BTOX” não são, por si, registrados; a regularidade é do produto utilizado. O SaaS deve exigir produto identificado, responsável, instrução do fabricante, validade e confirmação do profissional — não uma receita genérica pelo nome comercial.[^anvisa-metodos]
2. Formol e glutaraldeído não podem ser usados como alisantes. Para procedimentos químicos, o catálogo precisa ter bloqueio de produto proibido/irregular, declaração de ventilação e EPI, contraindicação, registro de intercorrência e rota de encaminhamento humano.[^anvisa-alisantes]
3. O próprio material de fabricantes mostra sequências semelhantes, mas não iguais: limpar/lavar, secar parcialmente, dividir, aplicar, pausar, secar, selar com calor, enxaguar e finalizar. Tempo, temperatura, número de passadas, enxágue e cuidados posteriores variam por fórmula, textura, histórico e marca.[^chi][^brazilian-blowout]
4. Teste de alergia e teste de mecha são preparos versionados: uma fonte profissional de coloração indica observação de 48 horas para teste de alergia e teste de mecha para orientar resultado e tempo. O sistema deve guardar data, produto/lote, resultado e validade configurável, jamais assumir que o teste está válido.[^wella]

> **Conclusão de produto:** o agente não deve instruir aplicação química passo a passo nem decidir segurança capilar. Ele coleta contexto, encontra a configuração aprovada pelo estabelecimento, verifica pré-requisitos e agenda/encaminha para avaliação humana quando houver bloqueio, incerteza, reação, incompatibilidade ou baixa confiança.

[^anvisa-metodos]: [Anvisa — Produtos alisantes e ondulantes para cabelo](https://www.gov.br/anvisa/pt-br/comunicacao/campanhas/estetica/produtos-alisantes-e-ondulantes-para-cabelo), acessado em 13/08/2026.
[^anvisa-alisantes]: [Anvisa — Alerta sobre alisantes irregulares](https://www.gov.br/anvisa/pt-br/assuntos/noticias-anvisa/2025/anvisa-alerta-para-riscos-a-saude-associados-ao-uso-de-alisantes-capilares-irregulares), 07/07/2025.
[^chi]: [CHI Education — Enviro-American Smoothing Treatment](https://education.chi.com/online-courses/chapter-11-salon-texture-services/lessons/chi-enviro/), acessado em 13/08/2026.
[^brazilian-blowout]: [Brazilian Blowout — Professional treatment steps](https://rewards.brazilianblowout.com/thingstoknow/steps/), acessado em 13/08/2026.
[^wella]: [Wella — Hair color safety tests](https://www.wella.com/international/wella-magazine/hair-color-safety-tests), acessado em 13/08/2026.

## Mensageria, CRM e campanhas: restrições de plataforma

| Decisão de arquitetura | Evidência externa | Consequência no produto |
|---|---|---|
| Manter catálogo de templates por tenant | Mensagens iniciadas fora da janela de atendimento requerem template; template precisa de categoria, idioma e status aprovado | `message_templates` deve ser sincronizado por WABA/número/tenant e bloquear o envio se não estiver `APPROVED` |
| Separar utilidade de marketing | A Meta classifica templates como `authentication`, `marketing` ou `utility`; a categoria afeta uso e preço | Uma lembrete de atendimento não pode ser disfarçado como promoção; motor de campanha só aceita template de marketing |
| Congelar público antes de disparar | O marketing exige template aprovado e tem limites/qualidade por usuário e template | A audiência é um snapshot idempotente, com motivo de elegibilidade por cliente, antes da aprovação humana |
| Consumir eventos de status e qualidade | Webhooks incluem mensagem recebida, status de saída, status/qualidade de templates e preferências de usuário | Inbox, consentimento/opt-out e campanhas precisam reagir a webhooks, não a suposições do painel |
| Processar idempotentemente | A Meta pode repetir tentativas de webhook por até sete dias quando a entrega falha | `event_id`/`message_id`, inbox/outbox e worker com deduplicação são obrigatórios |

[^meta-templates]: [Meta — Template fundamentals](https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview), atualizado em 21/05/2026, acessado em 13/08/2026.
[^meta-marketing]: [Meta — Send Marketing Messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/marketing-messages/send-marketing-messages), atualizado em 21/05/2026, acessado em 13/08/2026.
[^meta-webhooks]: [Meta — WhatsApp Webhooks](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview), atualizado em 26/06/2026, acessado em 13/08/2026.

## Lacunas que impedem declarar o SaaS vendável hoje

- Motor determinístico de agenda e reservas concorrentes ainda não têm evidência final nesta rebaselinação.
- Integrações Google Calendar, WhatsApp, pagamento, STT e visão precisam ser tratadas como contratos independentes, idempotentes e auditáveis.
- O CRM de recorrência exige registrar tratamentos **executados**, não apenas procedimentos agendados, e manter a próxima janela como regra configurável, nunca “vencimento” clínico universal.
- O agente do proprietário exige permissões, plano de ação, prévia, confirmação e trilha de auditoria; um chat com capacidade de escrever no banco é risco crítico.
- Fotos, histórico químico e mensagens ampliam significativamente a superfície LGPD e a política de retenção.

## Próxima consolidação

O documento será complementado com: taxonomia configurável de procedimentos, requisitos completos, modelo de domínio revisado, arquitetura de agentes/ferramentas, controles de CRM/campanha e backlog por gates de produção.
