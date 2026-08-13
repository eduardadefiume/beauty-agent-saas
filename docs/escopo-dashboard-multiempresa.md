# Escopo rebaselined — Dashboard operacional multiempresa

**Artefato:** escopo de produto e limites da próxima implementação  
**Status:** documentado; não implementado; não aprovado para produção  
**Decisão da proprietária:** manter o configurador como raiz do produto e incluir CRM, campanhas e módulos de expansão no escopo do dashboard.

## 1. Decisão de produto

O produto não terá um “Dashboard William” como destino universal. O salão do William é o primeiro piloto, não uma categoria fixa do sistema. O dashboard deve ser uma área operacional genérica e resolver o **tenant ativo do usuário autenticado**. Assim, cada proprietário vê exclusivamente o seu negócio, sua equipe, seus clientes, suas conversas, sua agenda e seus dados de operação.

O configurador permanece na rota raiz (`/`), pois é o local em que cada negócio define suas políticas e capacidades. O dashboard fica em `/dashboard` e recebe uma entrada explícita no configurador. O pós-login continua no configurador, evitando que um novo cliente seja lançado em uma experiência associada visual ou semanticamente ao William.

> **Princípio inegociável:** nenhuma referência de nome, imagem, número, serviço, evento, KPI ou regra do William pode ser usada como fallback para outro tenant.

## 2. Escopo funcional rebaselined

| Área | Entra no escopo do produto | Limite operacional inicial | Situação atual |
|---|---|---|---|
| Configurador | Sim | Negócio, equipe, serviços, agenda e políticas | Implementado parcialmente; destino atual após login |
| Dashboard operacional | Sim | Visão de saúde do negócio, agenda, WhatsApp e ações pendentes do tenant | Protótipo visual hoje fixado ao piloto William; precisa ser generalizado |
| WhatsApp / inbox | Sim | Eventos e conversas do próprio tenant, estados de atendimento e transferência humana futura | Integração e evidências parciais; não validado ponta a ponta em produção |
| Agenda e confirmações | Sim | Agendamentos, disponibilidade, confirmação, remarcação e cancelamento orientados por regras | Em desenvolvimento; não declarar operacional sem teste determinístico |
| Política de sinal | Sim | Regra configurável, estado de cobrança e bloqueio/continuidade conforme confirmação verificável | Escopo do wedge; pagamento automático ainda não conectado |
| CRM | Sim | Perfil progressivo do cliente, histórico operacional, consentimentos, preferências e pesquisa por tenant | A ser especificado e modelado; não implementado |
| Campanhas | Sim | Segmentação explicável, elegibilidade, prévia, aprovação humana, descadastro, frequência e auditoria | A ser especificado e modelado; não habilitar disparos reais antes dos controles |
| Agente do proprietário | Sim | Consultas e ordens futuras com prévia, confirmação e auditoria | Escopo de expansão; não implementado |
| Foto, STT e pagamentos automáticos | Sim, como expansão | Devem obedecer regras determinísticas, confiança, consentimento e evidência verificável | Não implementados |

## 3. Navegação e comportamento pós-autenticação

O comportamento aprovado é o seguinte:

1. Após cadastro, login ou redefinição de senha, o usuário vai para `/`, o configurador do **seu** tenant.
2. A navegação principal mostra uma entrada clara para `Dashboard operacional`.
3. Em `/dashboard`, a identidade e os dados são resolvidos a partir do tenant autorizado do usuário; o usuário não escolhe nem consegue inferir outro tenant por URL, armazenamento local ou valor de fallback.
4. Sem tenant ativo, o sistema apresenta estado seguro de configuração inicial, nunca dados de William ou de outro negócio.

## 4. Requisitos de governança já assumidos

CRM e campanhas não podem ser adicionados somente como páginas de interface. Antes de qualquer envio externo, o produto deve ter autorização por tenant, consentimento verificável, motivo de segmentação, lista de destinatários em prévia, aprovação explícita do proprietário, descadastro, limite de frequência, trilha de auditoria e proteção contra duplicidade. As conversas de WhatsApp seguem a mesma regra de isolamento e não podem expor uma caixa de entrada global.

| Controle | Aplicação obrigatória |
|---|---|
| Isolamento por `tenant_id` | Todas as consultas, comandos e arquivos; com RLS no Supabase e validação de autorização no backend |
| Papel e permissão | Acesso ao dashboard e às ações separado por função; campanhas exigem aprovação autorizada |
| Consentimento e descadastro | Persistidos por cliente e canal, com data, origem e revogação verificável |
| Auditoria | Registro do autor, tenant, ação, critério usado, itens afetados e resultado |
| Idempotência | Webhooks, confirmações e futuros disparos não podem duplicar efeitos |
| Dados mínimos | O dashboard exibe somente o necessário à ação operacional e respeita retenção/exclusão |

## 5. Critério de corte entre escopo e ativação

O escopo do produto está ampliado, mas a ativação deve ser incremental. Colocar CRM e campanhas no escopo **não** autoriza campanha automática no piloto sem os controles acima. O primeiro incremento visual pode apresentar os módulos no dashboard e seus estados de configuração; o primeiro incremento funcional deve começar pelo CRM mínimo e pela prévia de campanha, sem disparo. Disparo real só entra quando consentimento, aprovação e auditoria forem testados com evidência.

## 6. Status verificável

| Elemento | Estado comprovado | Evidência |
|---|---|---|
| Login e redefinição de senha | Conectado e testado manualmente | Fluxo executado pela proprietária no domínio principal |
| Configurador na raiz | Implementado e acessível | Rota `/` após autenticação |
| Dashboard editorial atual | Implementado em preview, mas específico ao William | Preview Vercel do commit `c1794ae` |
| Dashboard multiempresa por tenant | Documentado | Este artefato; implementação pendente |
| CRM e campanhas governados | Documentado como escopo | Modelagem, requisitos e implementação pendentes |
| Produção do dashboard integrado | Não promovido | Domínio principal continua na configuração atual |

## Perguntas que bloqueiam o próximo passo

1. No primeiro corte funcional de CRM, você quer começar por **perfil e histórico do cliente** ou por **inbox/conversas do WhatsApp**? Ambos serão parte do produto, mas precisam de uma ordem de implementação.
2. Para campanhas, o primeiro corte deve ser apenas **segmentação + prévia + aprovação** (sem envio) ou você pretende habilitar também o envio real ao piloto, sujeito a consentimento e templates aprovados?
