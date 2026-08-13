# Requisitos — SaaS de Agente de IA para Negócios de Beleza

**Status:** especificação aprovada para validação da fundadora; não implementada como conjunto.  
**Referências:** `escopo-saas-completo.md`, `biblioteca-procedimentos-capilares-configuraveis.md`, `CONTEXTO.md` e dossiê completo.

## 1. Requisitos funcionais

### 1.1 Multiempresa, identidade e governança

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-ORG-01 | O sistema deve manter tenant, unidade, usuário, papel, equipe e canal identificados em cada registro operacional. | Uma consulta autenticada não retorna dados de outro `tenant_id`; teste negativo comprova bloqueio. |
| RF-ORG-02 | A proprietária deve cadastrar e alterar perfil de negócio, horários, endereço, segmento, políticas, unidades e canais. | Alteração fica visível, persiste após recarga e muda a regra que a consome. |
| RF-ORG-03 | O sistema deve suportar papéis configuráveis, no mínimo proprietária, gerente, profissional, assistente e atendimento. | Ação fora da permissão retorna erro e é auditada. |
| RF-ORG-04 | Toda operação externa ou de alto impacto deve registrar ator, tenant, motivo, antes/depois, correlação e resultado. | Auditoria reconstrói quem aprovou, enviou, alterou ou cancelou. |

### 1.2 Catálogo de procedimentos, serviços e variações

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-CAT-01 | O estabelecimento deve criar serviços simples e compostos, inativar e versionar fichas publicadas. | Serviço composto publicado preserva a versão usada em atendimento anterior. |
| RF-CAT-02 | Um serviço composto deve conter etapas ordenadas, condicionais e rastreáveis. | Simulação apresenta sequência, responsáveis, recursos, pausas e duração total corretos. |
| RF-CAT-03 | Cada etapa deve permitir profissional/habilidade, recursos, bloqueio/liberação, produto, preparo, duração, pausa e evidência de execução. | Motor de agenda rejeita horário que conflita com qualquer recurso ou pessoa bloqueada. |
| RF-CAT-04 | O estabelecimento deve definir variações por comprimento, densidade, textura, técnica, condição, data, unidade e profissional. | A regra determinística retorna preço/duração ou `AVALIAÇÃO_NECESSÁRIA`; nunca valor inventado. |
| RF-CAT-05 | Procedimentos químicos devem permitir pré-requisito, produto, instrução, teste, responsável e bloqueios configuráveis. | Serviço não pode ser ofertado se pré-requisito marcado como obrigatório não estiver validado. |
| RF-CAT-06 | A biblioteca de procedimentos deve ser adaptável a cabelo, cílios, unhas e segmentos futuros. | Um tenant de cílios cria etapas próprias sem campos obrigatórios de química capilar. |

### 1.3 Perfil de cliente, imagens e histórico técnico

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-CLI-01 | O sistema deve criar/atualizar contato progressivamente a partir de canal autorizado e identificar duplicidades. | A mesma identidade de WhatsApp não cria dois contatos no mesmo tenant. |
| RF-CLI-02 | O perfil deve suportar preferências, restrições informadas, atributos de cabelo, histórico técnico e observações com origem. | Campo mostra autor, fonte, data e revisão; dado sem origem não habilita automação de alto impacto. |
| RF-CLI-03 | Fotos devem ter consentimento específico, finalidade, retenção e vínculo com o registro técnico. | Sem consentimento, upload/uso analítico é bloqueado; exclusão remove referência e agenda remoção do arquivo. |
| RF-CLI-04 | O sistema deve armazenar atendimento e etapas `EXECUTADAS`, incluindo duração real e ficha versionada. | “Último procedimento” deriva de execução, não de agenda pendente/cancelada. |
| RF-CLI-05 | Uma análise visual deve retornar hipótese, campos extraídos, confiança, perguntas faltantes e necessidade de revisão. | Baixa confiança impede preço final, química e atualização automática do perfil. |

### 1.4 Agenda, disponibilidade, sinal e execução

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-AGD-01 | O motor deve calcular disponibilidade por etapas, profissional, habilidade, recurso, pausa, turno, exceção e término máximo. | Caso de teste com conflito em uma etapa não oferece o horário. |
| RF-AGD-02 | Uma reserva deve ter máquina de estados e prevenção de dupla reserva. | Duas solicitações concorrentes não confirmam o mesmo recurso/intervalo. |
| RF-AGD-03 | Sinal, cancelamento, atraso, reembolso e no-show devem seguir políticas com precedência explícita. | Explicação mostra qual regra foi aplicada e por que regras inferiores foram descartadas. |
| RF-AGD-04 | Google Calendar deve sincronizar sem criar loops, duplicidades ou dados fora do tenant/unidade. | Evento externo é reconciliado por chave de origem e auditoria; repetição é inócua. |
| RF-AGD-05 | Reagendamento por cliente ou proprietário deve propor alternativas e exigir escolha/confirmação apropriada. | Nenhuma cliente tem horário trocado silenciosamente. |

### 1.5 WhatsApp, inbox e atendimento humano

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-WA-01 | O sistema deve usar WhatsApp Business Platform oficial, validar webhook e deduplicar eventos. | Reenvio de webhook não duplica mensagem, contato, conversa nem efeito externo. |
| RF-WA-02 | A inbox deve exibir conversa, mensagem, direção, status de entrega, responsável, pausa e contexto permitido. | Usuário só vê conversas do tenant autorizado e pode assumir/liberar conforme papel. |
| RF-WA-03 | O agente deve suportar texto, áudio transcrito e foto com indicação da confiança/limite. | Falha de mídia resulta em pedido de reenvio ou escalonamento, sem dado fabricado. |
| RF-WA-04 | O negócio deve poder pausar o agente por conversa, canal, unidade ou tenant. | Durante a pausa, nenhuma resposta automática é enviada e a inbox sinaliza o motivo. |
| RF-WA-05 | Templates e seus status/qualidade devem ser sincronizados por tenant/WABA. | Um template sem aprovação ou sem categoria adequada não é selecionável para envio. |

### 1.6 CRM, recorrência, promoções e campanhas

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-CRM-01 | A CRM deve mostrar linha do tempo de contatos, conversas, agendas, execuções, observações, consentimentos e campanhas. | Filtro por contato mostra a origem e data de cada evento. |
| RF-CRM-02 | Regras de retorno devem derivar elegibilidade de um procedimento executado, política configurada e dados mínimos necessários. | Cliente sem execução ou sem consentimento não entra na audiência. |
| RF-CRM-03 | Segmentos devem combinar recência, frequência, procedimento, características permitidas, unidade e consentimento, com justificativa por cliente. | Preview mostra “por que entrou” e “por que foi excluída” para cada contato. |
| RF-CRM-04 | Promoções devem ter vigência, condições, serviço elegível, desconto/benefício, exclusões e política de uso. | Motor de agendamento aplica apenas promoções vigentes e elegíveis. |
| RF-CRM-05 | Campanha deve exigir template aprovado, consentimento por canal/finalidade, limite de contato, snapshot de destinatários e aprovação humana. | Não existe endpoint de envio que aceite campanha não aprovada. |
| RF-CRM-06 | Descadastro e preferências devem interromper marketing futuro e ficar auditados. | Uma mensagem de opt-out altera a elegibilidade antes do próximo worker. |
| RF-CRM-07 | Disparo deve ser idempotente, registrando tentativa, status Meta, falha e correlação. | Retentativa não envia duas vezes ao mesmo destinatário para a mesma campanha. |

### 1.7 Agente conversacional e agente do proprietário

| ID | Requisito | Critério de aceite verificável |
|---|---|---|
| RF-AI-01 | A IA deve interpretar intenção, recuperar contexto permitido e responder em linguagem natural concisa. | Cenários de teste mostram resposta com dado do motor, sem preço/horário inventado. |
| RF-AI-02 | O agente deve fazer apenas uma pergunta objetiva por vez quando houver dado bloqueante. | Transcrição de conversa não contém lista de perguntas simultâneas para avançar. |
| RF-AI-03 | Toda ação deve ser executada via ferramenta tipada, com política, validação e idempotência. | Prompt malicioso não aciona ferramenta fora do contrato; tentativa é registrada. |
| RF-AI-04 | O agente do proprietário deve transformar intenção em plano de ação, prévia de impacto e confirmação explícita. | “Avise clientes” lista destinatários, mensagem, motivo, frequência e confirmação antes do envio. |
| RF-AI-05 | Perguntas técnicas devem usar conhecimento aprovado e limites claros, escalando avaliação humana em risco ou incerteza. | O agente não diagnostica, não prescreve e não confirma compatibilidade química sem regra/profissional. |

## 2. Requisitos não funcionais

| ID | Atributo | Exigência verificável |
|---|---|---|
| RNF-SEC-01 | Isolamento | RLS forçada e autorização server-side em toda tabela/rota multiempresa; teste de vazamento negativo. |
| RNF-SEC-02 | Privacidade/LGPD | Base legal/finalidade, minimização, consentimento, exportação, retenção e eliminação por tipo de dado. |
| RNF-SEC-03 | Segredos | Tokens Meta, Calendar e pagamentos fora do banco de domínio, em cofre/segredo gerenciado, com rotação. |
| RNF-REL-01 | Idempotência | Webhooks, reservas, pagamentos e envios possuem chave estável e toleram reentrega. |
| RNF-REL-02 | Recuperação | Filas possuem DLQ, replay controlado, alertas e reconciliação. |
| RNF-OBS-01 | Observabilidade | Cada fluxo externo tem `correlation_id`, logs estruturados, métricas e painel de falhas. |
| RNF-PERF-01 | Responsividade | Inbox e agenda carregam de forma paginada; tarefas longas são assíncronas e informam estado. |
| RNF-AI-01 | Segurança de IA | Dados enviados ao modelo são minimizados; ferramentas seguem allowlist e schema; decisões críticas são determinísticas. |
| RNF-ACC-01 | Acessibilidade | Configurador, inbox e confirmação de ação suportam teclado, foco visível, contraste e textos de erro compreensíveis. |
| RNF-QUAL-01 | Evidência | Nenhuma feature é “pronta” sem UI, persistência, motor, falha controlada e teste automatizado/manual registrado. |

## 3. Casos de uso críticos

| Caso | Fluxo resumido | Resultado seguro |
|---|---|---|
| CU-01: primeira mensagem | Cliente pergunta por serviço pelo WhatsApp | Agente coleta mínimo contexto, usa catálogo do tenant e propõe próxima ação válida. |
| CU-02: orçamento variável | Cliente pede preço de técnica capilar | Motor retorna faixa/regra ou exige avaliação; agente não cria preço. |
| CU-03: química com pré-requisito | Cliente quer tratamento de textura | Agente verifica ficha/teste/revisão e agenda avaliação se faltar condição. |
| CU-04: agendamento composto | Cliente agenda serviço com pausa e recursos | Solver reserva sequência inteira ou oferece alternativas válidas. |
| CU-05: execução e CRM | Profissional conclui atendimento | Sistema registra etapas, duração real e recalcula janela de retorno. |
| CU-06: promoção de retorno | Proprietária cria oferta para serviço recorrente | Segmento explica elegibilidade, congela público e aguarda aprovação. |
| CU-07: remarcação em massa | Profissional falta | Agente produz impacto e alternativas; só envia após confirmação. |
| CU-08: imagem ambígua | Cliente envia foto de cabelo | Modelo extrai hipótese/confiança e encaminha avaliação, sem confirmar preço/química. |

## 4. Critérios de bloqueio comercial

O produto não pode ser anunciado como “agente de IA que agenda e faz campanhas” enquanto qualquer um dos seguintes estiver ausente: isolamento comprovado, agenda concorrente testada, consentimento/opt-out aplicado, template aprovado sincronizado, aprovação humana de campanha, idempotência de envio, pausa global, auditoria, fluxo de falha e validação com dados reais autorizados. Esses itens não são refinamento; são o mínimo para não vender um risco operacional disfarçado de IA.
