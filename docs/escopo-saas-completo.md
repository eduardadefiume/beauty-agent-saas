# Escopo de Produto — SaaS de Agente de IA para Negócios de Beleza

**Status:** especificado para rebaselinação; não equivale a módulos implementados.  
**Decisão de produto:** a fundadora substituiu o recorte exclusivo do wedge inicial pelo objetivo de produto comercial completo.  
**Fonte prioritária:** `CONTEXTO.md`, dossiê completo fornecido e solicitação da fundadora em 13/08/2026.

## 1. Objetivo de negócio e fronteira do produto

O produto é um SaaS multiempresa para salões, cabeleireiros, studios de cílios, manicures e negócios de beleza que centraliza configuração do negócio, agenda, atendimento por WhatsApp, histórico técnico de clientes, CRM e campanhas controladas. Cada estabelecimento opera dentro do seu próprio `tenant_id`, com dados, catálogo, equipe, políticas, WABA, clientes e auditoria isolados.

O primeiro recorte técnico detalhado será **capaz de atender cabelo**, porque este é o domínio com maior combinação de duração, risco químico, preço variável e recorrência. Os demais segmentos usam o mesmo núcleo de agenda, CRM, consentimento e agentes, mas terão seus próprios catálogos e protocolos configuráveis; não serão forçados a caber em campos de cabeleireiro.

> O produto não vende “resposta automática no WhatsApp”. Ele vende operação confiável: a IA interpreta e conversa, enquanto regras determinísticas controlam preço, disponibilidade, segurança, elegibilidade e execução de ações.

## 2. Dentro e fora do escopo

| Em escopo de produto | Fora de escopo ou bloqueado |
|---|---|
| Onboarding de empresa, unidade, equipe, papéis e permissões | Diagnóstico médico, tricologia clínica ou prescrição química pela IA |
| Catálogo de serviços simples, compostos e variações | Protocolo universal de marca para química, cor ou alisamento |
| Agenda determinística, reservas, sinal e integrações configuradas | Oferta de horário, preço ou promoção inventados pela LLM |
| WhatsApp oficial, inbox, transferência humana e automações permitidas | WhatsApp Web, scraping de contatos ou campanhas sem opt-in |
| CRM técnico de cliente, fotos consentidas, histórico realizado e recorrência | Inferir etnia, condição de saúde ou tipo de cabelo “verdadeiro” por foto |
| Segmentação, promoções, prévia, aprovação e disparo auditável | Disparo autônomo de campanhas ou alteração silenciosa de agenda |
| Agente do proprietário com leitura, plano e ações confirmadas | Agente com acesso irrestrito ao banco ou a segredos |

## 3. Módulos de produto

| Módulo | Resultado para o estabelecimento | Regra de qualidade |
|---|---|---|
| Negócio e acesso | Configura a operação e enxerga somente o próprio tenant | RLS, papéis, logs e segregação por tenant |
| Catálogo técnico | Define serviços, etapas, variações, preços e pré-requisitos | Mudança versionada; nunca altera retroativamente um atendimento realizado |
| Equipe e recursos | Configura aptidões, turnos, substitutos, cadeiras, lavatórios, salas e equipamentos | Agenda bloqueia conflitos de pessoa e recurso |
| Agenda e pagamento | Faz, confirma, remarca, cancela e registra sinal conforme política | Motor determinístico, idempotente e com trilha de estados |
| WhatsApp e inbox | Recebe mensagens, áudio, imagem e status; permite atendimento humano | API oficial, deduplicação, pausa de emergência e auditoria |
| Perfil técnico e CRM | Guarda cadastro progressivo, histórico executado, preferências, consentimento e relacionamento | Dados mínimos, proveniência e retenção configurável |
| Campanhas | Cria público explicável e envia somente após aprovação | Consentimento, template elegível, frequência, opt-out, snapshot e auditoria |
| Agente da cliente | Responde, coleta dados, estima com limites e propõe próximas ações | Ferramentas determinísticas e escalonamento humano |
| Agente do proprietário | Consulta operação e cria planos de ação sobre agenda/clientes | Prévia, confirmação explícita, permissões e log por ação |
| Observabilidade e segurança | Mede saúde, falhas, custo e risco por tenant | Alertas, correlação, retenção, backup e revisão LGPD |

## 4. Catálogo técnico de cabelo: princípio de configuração

Uma ficha de serviço não é apenas “nome + preço + duração”. Ela pode representar um serviço composto por etapas ordenadas, cada uma com duração prevista, pessoa responsável, recursos, bloqueio ou liberação de profissional, produto, pausa, pré-requisito e regra de variação. O estabelecimento escolhe o que usa; o SaaS oferece estrutura, não receita química fixa.

### 4.1 Famílias iniciais de procedimento

| Família | Exemplos comerciais | O que é configurável |
|---|---|---|
| Corte e styling | corte feminino/masculino, franja, escova, babyliss | técnica, profissional, extensão/densidade, lavagem, finalização, preço e duração |
| Tratamento cosmético | hidratação, nutrição, reconstrução, detox, spa capilar | produto, preparo, pausas, calor, enxágue, finalização e recomendações de retorno |
| Coloração | raiz, tonalização, global, correção, mechas, balayage | mistura/produto, teste, técnica, comprimento, cobertura, pausa, matização, preço e duração |
| Textura e alisamento | redução de volume, alinhamento, relaxamento, permanente | produto registrado, compatibilidade, teste, EPI, ventilação, aplicação, pausa, lavagem, calor, cuidados e janela de revisão |
| Penteado e evento | coque, trança, bridal, maquiagem associada | prova, acessórios, sinal, deslocamento, tempo, equipe e política de cancelamento |
| Extensões e remoção | aplicação, manutenção, remoção | método, quantidade, material, manutenção, restrições e custo de insumos |

### 4.2 Biblioteca de tipos de etapa

`ETAPA` deve ser uma entidade configurável, mas o produto inicia com uma biblioteca segura de tipos: avaliação, anamnese, teste de mecha, teste de alergia, registro de foto, preparo/lavagem, secagem parcial, divisão, proteção, aplicação, pausa, processamento, enxágue, neutralização, secagem, selagem térmica, corte, finalização, orientação pós-serviço, pagamento e revisão. Cada tipo suporta instruções internas aprovadas pelo estabelecimento, sem instruções perigosas geradas pelo modelo.

| Campo da etapa | Exemplos e impacto |
|---|---|
| Ordem e condição de entrada | “teste aprovado”, “sinal confirmado”, “cliente presente” |
| Duração e pausa | duração fixa, faixa, por variação; pausa pode liberar profissional e manter recurso |
| Responsável e habilidade | colorista, assistente, profissional certificado, substituto permitido |
| Recursos | lavatório, cadeira, sala, secador, prancha, kit de proteção |
| Produto e instrução | marca, linha, lote opcional, validade, instrução/anexo, dados de segurança |
| Segurança | EPI, ventilação, contraindicação, teste obrigatório, necessidade de dupla checagem |
| Resultado | evidência executada, foto consentida, observação, duração real e cuidados pós |

### 4.3 Exemplo abstrato: tratamento de alinhamento sem formol

O sistema pode montar: **avaliação → pré-requisito/teste quando exigido → lavar → secar parcialmente → dividir → aplicar produto → pausa conforme produto/tipo configurado → secar → selar com calor configurado → enxaguar quando a ficha exigir → finalizar → cuidados posteriores/revisão**. Isso é um *template de fluxo*, não um protocolo universal. A ficha só fica publicável se o profissional responsável vinculou produto aprovado, instrução do fabricante e guardrails obrigatórios.[^anvisa]

## 5. Conhecimento visual e tipo de cabelo

O configurador oferecerá um **perfil descritivo**, não uma classificação racial ou diagnóstico: padrão de forma (liso/ondulado/cacheado/crespo e subtipos livres do estabelecimento), comprimento, densidade, espessura, porosidade declarada, condição observada, cor/técnica atual e histórico químico. A cliente pode informar o perfil; o profissional pode revisar; fotos são evidência opcional com consentimento específico.

As imagens do configurador devem ser ilustrações educativas diversas, neutras e produzidas/licenciadas pelo produto, nunca fotos de clientes reaproveitadas. Elas ajudam seleção e comunicação, mas não concluem preço, compatibilidade ou risco. Análise de foto retorna hipóteses estruturadas, nível de confiança e perguntas faltantes; em baixa confiança ou impacto em preço/química, exige revisão humana.

## 6. CRM de relacionamento e recorrência

O CRM registra eventos com data e proveniência: contato/canal, atendimento agendado, atendimento executado, serviços e etapas realizadas, produtos declarados, observações, fotos consentidas, duração real, cancelamentos, consentimentos e interações. O procedimento “mais recente” é derivado de um atendimento **executado**, não apenas de um agendamento.

Uma **regra de recorrência comercial** por serviço/variação define janela-alvo, tolerância, início da elegibilidade, oferta permitida e exceções. O termo no produto será “janela de retorno sugerida”, não “vencimento” clínico. Exemplo configurável: “após `X` dias da execução de serviço Y, se houver consentimento de marketing, não houver opt-out e a frequência máxima permitir, candidatar a oferta de 10% válida até `Z`”. A promoção ainda depende de template aprovado, público congelado e aprovação humana.

## 7. Agentes de IA e limites de ação

| Agente | Pode fazer | Não pode fazer sozinho |
|---|---|---|
| Conversacional da cliente | responder FAQ aprovada, interpretar intenção, coletar contexto, consultar catálogo/agenda/política, propor horários e criar rascunho de reserva | confirmar preço variável sem regra, pular pré-requisito, prometer resultado, executar química, disparar campanha |
| Agente técnico de cabelo | explicar cuidados aprovados, identificar lacunas, orientar avaliação profissional e consultar protocolos versionados | diagnosticar doença, declarar compatibilidade química, decidir tratamento com base exclusiva em foto |
| Agente do proprietário | consultar KPI, localizar clientes, propor mensagens, gerar plano de remarcação e prévia de público | enviar externamente, mover agenda, alterar política, conceder desconto ou apagar dado sem confirmação e permissão |
| Orquestrador | chamar ferramentas determinísticas e aplicar políticas | inferir regras fora do catálogo/política/estado autorizado |

## 8. Definição de “operável para venda” 

O SaaS só pode ser oferecido comercialmente quando cada capacidade anunciada tiver interface utilizável, persistência, aplicação no motor correspondente, controles de falha, logs, testes de isolamento e evidência de integração. Hoje, a produção tem configurador e dashboard multiempresa publicados; a base de CRM foi aplicada no DEV. Isso **não autoriza** vender como CRM inteligente, campanhas reais, agente técnico ou agenda autônoma até que os módulos e suas integrações estejam implementados e validados.

[^anvisa]: [Anvisa — produtos alisantes e ondulantes para cabelo](https://www.gov.br/anvisa/pt-br/comunicacao/campanhas/estetica/produtos-alisantes-e-ondulantes-para-cabelo) e [alerta sobre alisantes irregulares](https://www.gov.br/anvisa/pt-br/assuntos/noticias-anvisa/2025/anvisa-alerta-para-riscos-a-saude-associados-ao-uso-de-alisantes-capilares-irregulares), acessados em 13/08/2026.
