# Auditoria G0/G1 — fundação e catálogo técnico

## Escopo auditado

Foram auditados o modelo configurável já persistido em `app.configuration_drafts`, o gateway `public.site_replace_configuration`, o snapshot de carregamento e a interface do configurador. A auditoria confirma que o produto **já possui uma base útil**: serviços, variações, etapas, recursos, competências, profissionais, disponibilidade, revisão otimista por `revision` e isolamento por `tenant_id`/`configuration_draft_id`.

O modelo atual não é, contudo, um catálogo técnico vendável. Ele permite descrever agenda, mas não representa de maneira verificável o protocolo de atendimento, as condições de segurança, produtos, contraindicações ou o que o agente pode afirmar sem escalar a uma profissional.

| Área | Estado encontrado | Decisão G1 |
|---|---|---|
| Versionamento | Serviços e etapas já pertencem a um `configuration_draft`; a revisão é incrementada a cada substituição | Reutilizar o versionamento existente; não criar uma segunda noção de versão |
| Isolamento | Chaves compostas e gateway autorizam `OWNER`/`ADMIN` por tenant | Manter `tenant_id` e `configuration_draft_id` em todas as novas tabelas e exigir FKs compostas |
| Agenda | Passos possuem posição, duração, tipo ativo/passivo, competência e recursos | Acrescentar semântica técnica e limites operacionais às etapas existentes |
| Químicas | Há teste de mecha configurável por serviço, mas sem motivo, instrução ou confirmação profissional | Criar protocolo técnico e controles de segurança por serviço; nunca codificar tempo ou receita de marca |
| Interface | O configurador já edita serviços e etapas, porém somente campos de agenda | Adicionar uma configuração inicial de perfil técnico, condições e etapas, sem expor campos clínicos ou de diagnóstico pela IA |
| Agente | Não existe contrato de ferramenta nem regra de escalonamento para conhecimento técnico | Não implementar resposta autônoma antes de existir catálogo publicado e regras de escalonamento |

## Fatia G1 aprovada para implementação

1. Criar um **perfil técnico por serviço** no draft: família, finalidade, instrução do fabricante, exigência de avaliação profissional, teste de mecha e política de liberação.
2. Estender as etapas existentes com uma **categoria semântica**, tempo mínimo/máximo operacional, confirmação profissional e registro obrigatório de produto/lote quando aplicável.
3. Criar requisitos e alertas técnicos estruturados por serviço, com severidade e ação obrigatória. Eles são informação configurada pelo estabelecimento, não orientação médica gerada pela IA.
4. Passar todos os campos pelo mesmo ciclo já existente: interface → payload → `site_replace_configuration` → snapshot → gateway → interface.
5. Validar constraints, isolamento e recusa de payload malformado. Nenhum template clínico, produto ou protocolo de marca será pré-semeado.

## Limites deliberados desta fatia

Esta entrega não implementa ainda análise de imagem, prontuário técnico de cliente, execução de atendimento, campanhas, agente com ferramenta ou catálogo central de produtos. Esses módulos dependem do protocolo publicado e de uma trilha de consentimento/auditoria. Implementá-los antes criaria dados e promessas que o motor ainda não pode sustentar.

## Evidência

| Evidência | Situação |
|---|---|
| Esquema atual e gateway revisados | Documentado |
| Nova fatia de schema | Implementada no arquivo de migração; pendente de validação remota independente |
| Migração executada em Supabase DEV | Retorno transacional de sucesso observado; schema, RLS e contratos ainda não verificados por consulta independente |
| UI conectada à persistência | Implementada localmente; contrato remoto ainda pendente de validação independente |
| Teste de isolamento e de contrato | Pendente |
