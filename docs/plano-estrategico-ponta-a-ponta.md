# Plano Estratégico Ponta a Ponta — SaaS de Agente de IA para Negócios de Beleza

**Data:** 17 de agosto de 2026
**Autoria da análise:** auditoria técnica sobre o repositório `eduardadefiume/beauty-agent-saas` (HEAD `d326884`), o banco Supabase DEV `hjghwryhphgusefyivbl` (consultado ao vivo), o dossiê de 01/08/2026 e os 20 documentos do Manus.
**Regra de leitura:** este documento separa **alegado** de **comprovado**. Onde há prova, ela está citada. Onde não há, está escrito "não verificado".

---

## 1. Veredito em uma página

Você não está andando em círculos por falta de trabalho. Está andando em círculos por **três causas estruturais concretas**:

1. **Três modelos de dados rivais para a mesma coisa** (WhatsApp/CRM). Cada rodada de trabalho criou um novo conjunto de tabelas em vez de convergir o anterior. Duas das três ondas não têm **nenhum** código chamando-as.
2. **A camada de evidência mede a coisa errada.** Os relatórios de prontidão comprovam *existência de tabela e de constraint*, não *funcionamento de produto*. Por isso um módulo pode ser declarado "concluído" e ainda assim não ter um único chamador.
3. **A superfície mais visível (`/dashboard`) é a menos ancorada em dados.** Ela exibe "Concluído", "verificação concluída", "persistência ativa" a partir de strings fixas no código. Isso destrói sua própria capacidade de saber onde você está.

O que **é** real e bom: o motor de agenda determinístico em SQL, o configurador com versionamento e trava otimista, a integração Google Calendar, e o webhook do WhatsApp. Essa base é sólida e não deve ser reescrita.

E existe **uma emergência de segurança que precisa ser resolvida antes de qualquer outra coisa** — detalhada na seção 3.

---

## 2. Estado real comprovado, módulo a módulo

Legenda: ✅ funciona · 🟡 existe parcialmente · ❌ não funciona · 🔵 só schema, sem produto

| Módulo | Alegado nos relatórios | Estado comprovado | Evidência |
|---|---|---|---|
| Multiempresa / RLS | "39 migrações, RLS ativa" | 🟡 46 migrations, 55 tabelas. RLS habilitada em todas, mas **15 tabelas têm zero políticas** e 27 não têm `FORCE` | `pg_policies` e migrations |
| Configurador (`/`) | "implementado parcialmente" | ✅ **Melhor parte do produto.** 3.015 linhas, 8 de 14 módulos `ready:true`, persistência versionada com `expectedRevision` | `apps/web/app/configurator-real.tsx` |
| Motor de agenda | "em desenvolvimento" | ✅ Real, em SQL, com exclusion constraints GiST, holds idempotentes, ledger unificado | migration `20260808120000` |
| Simulador de agenda | — | ✅ Cria hold real, confirma, cancela, mostra `rejectionCounts` do motor | `scheduling-simulator.tsx` |
| Google Calendar | "não conectado" (dossiê) | ✅ **Conectado de verdade.** OAuth, refresh de token, leitura de eventos, persistência. 1 conexão ativa no DEV | `/api/calendar-sync`, `app.calendar_connections` |
| WhatsApp — webhook | "pronto para recepção" | 🟡 Código **correto** (HMAC-SHA256 constant-time, dedup por SHA-256, limite 1 MB). Mas **nenhuma mensagem real recebida**: `app.inbox_events` tem **0 linhas** | `supabase/functions/whatsapp-webhook/`, consulta ao DEV |
| WhatsApp — inbox/UI | "G3 concluído" | ❌ Zero chamadores das tabelas G3. Nenhuma tela lê conversa | `grep` sem resultados |
| Dashboard (`/dashboard`) | "generalizado para multiempresa" | ❌ 1 único dado real (nome do tenant). `inboxEvents = []` literal. Botões só emitem `toast()` afirmando ter verificado sem verificar | `dashboard/page.tsx:141,198,379,407` |
| Sinal / depósito (G2) | "implementado e auditado" | 🔵 Schema completo e bom. **Zero UI, zero endpoint, zero worker, zero agendador.** Expiração nunca roda sozinha | `grep deposit` em `apps/` = 0 |
| CRM | "sete tabelas com RLS" | 🔵 Tabelas em **dois modelos rivais**, ambos sem política de leitura e sem chamador | migrations `20260813114500`, `20260817120000` |
| Campanhas | "modelado" | 🔵 Só DDL. Sem fila, sem sync de template, sem opt-out, sem outbox | — |
| Agente conversacional | "motor de intenção processa" | 🟡 Edge Function `interpret-booking-intent` existe e é real (OpenAI, `store=false`). **Nenhum código no repositório a invoca** | `grep` = 0 chamadores |
| Agente da proprietária | "escopo de expansão" | ❌ Não existe | — |
| Pagamento | "pendente" | ❌ Nenhuma referência no repositório | — |
| Filas / workers | `apps/worker` | ❌ Stub de 20 linhas. Zero dependência de fila no monorepo | `apps/worker/src/main.ts` |
| n8n | "documentado" | ❌ Não provisionado | — |
| Backup | "implementado" | 🟡 Scripts existem (~1.400 linhas PowerShell). **Nunca executado nem restaurado** | `docs/operations/backup-and-recovery.md` |
| Produção | "eddigital.ia.br no ar" | ⚠️ **Não verificável deste ambiente** (egress bloqueado). Mas os **dois** projetos Supabase de produção estão `INACTIVE` | `list_projects` |

### 2.1 Fato que mais importa

**`app.inbox_events` tem 0 linhas.** Os relatórios "Prontidão Operacional — Piloto William" e "Atualização da Allowlist" afirmam que o sistema está "apto a receber mensagens" e "pronto para o disparo real". Isso é verdade como *configuração*. Mas **nenhuma mensagem real do WhatsApp jamais chegou ao banco**. O teste de ponta a ponta descrito nesses relatórios nunca foi concluído com sucesso — ou foi executado e falhou silenciosamente.

Esse é o teste único mais barato e mais informativo que existe hoje. Ele deve ser o primeiro item da Fase 2.

---

## 3. 🔴 EMERGÊNCIA DE SEGURANÇA — resolver antes de tudo

### 3.1 Exfiltração de tokens OAuth do Google por qualquer pessoa na internet

**Severidade: crítica. Explorável hoje. Dados reais expostos.**

A função `public.site_list_calendar_connections_for_sync` é `SECURITY DEFINER`, retorna **`accessToken` e `refreshToken` em texto claro**, e tem `EXECUTE` concedido ao papel **`anon`** — ou seja, é chamável por `POST /rest/v1/rpc/...` com a chave publicável que está embutida no JavaScript do site.

A autorização dela depende inteiramente de `private.require_site_tenant(site_project_id, email, tenant_id)`, que valida **apenas os três valores que o próprio chamador envia**. Não há `auth.uid()`, não há sessão, não há segredo:

```sql
-- private.require_site_tenant — a autorização inteira
not exists (
  select 1 from app.site_identities identity_record
   where identity_record.site_project_id = target_site_project_id
     and identity_record.email_normalized = lower(trim(target_email))
     and identity_record.tenant_id        = target_tenant_id
     and identity_record.status = 'ACTIVE'
) then raise exception ... 'SITE_TENANT_NOT_ACCESSIBLE';
```

Quem tiver a trinca acessa. E a trinca é obtível:

- `tenant_id` → **aparece na URL** `/dashboard?tenantId=<uuid>` (documentado no próprio `validacao-preview-dashboard-multiempresa.md`);
- `email` → obtível via `public.resolve_login_email(cpf)`, **também concedida ao `anon`**, que transforma um CPF no e-mail de login da proprietária;
- `site_project_id` → valor constante e de baixa entropia (`owner-console-v1`); há apenas **2 valores distintos** no banco.

**Confirmado no DEV:** existe 1 conexão de calendário com `access_token` **e** `refresh_token` preenchidos. Um *refresh token* do Google não expira com o tempo — dá acesso persistente à agenda do salão até ser revogado.

### 3.2 Superfície completa exposta ao `anon`

11 funções `SECURITY DEFINER` com `EXECUTE` para `anon`:

| Função | Impacto se explorada |
|---|---|
| `site_list_calendar_connections_for_sync` | **Vaza access/refresh token do Google** |
| `site_save_calendar_connection` | **Grava tokens arbitrários** no tenant da vítima |
| `site_record_calendar_shift_sync` | Injeta eventos falsos e sobrescreve tokens |
| `site_disconnect_calendar_connection` | Derruba a integração da vítima |
| `site_list_calendar_connections` | Enumera conexões e e-mails externos |
| `site_list_calendar_shifts` / `schedule_list_calendar_shifts` | Lê a agenda |
| `schedule_list_strand_test_occupancies` | Lê ocupação |
| `schedule_record_strand_test_booking` | **Escreve na agenda** da vítima |
| `site_start_new_draft` | Cria rascunho de configuração |
| `resolve_login_email` | **CPF → e-mail de login** (LGPD), sem rate limit |

### 3.3 A correção — verificada como segura

Consultei quem chama cada uma dessas funções. **As 10 primeiras são invocadas exclusivamente pelas Edge Functions `owner-console-api` e `scheduling-api`, que usam `service_role`** — e `service_role` já tem `EXECUTE` em todas as 11. Portanto:

> **Revogar `anon` e `authenticated` dessas 10 funções não quebra absolutamente nada.** É uma correção de uma linha por função, imediata e reversível.

`resolve_login_email` é a exceção: é chamada com a chave `anon` a partir de `apps/web/app/api/auth/login/route.ts:15` e `signup/route.ts`. Como essas rotas rodam **no servidor Next.js**, a correção é trocar a chave anônima pela secreta nessas duas rotas e então revogar o `anon`. É uma mudança de ~4 linhas.

**Migração de contenção pronta para aplicar:**

```sql
-- F0-01: fechar RPCs SECURITY DEFINER expostas ao papel anônimo.
-- Seguro: todas são chamadas apenas por Edge Functions com service_role.
revoke execute on function public.site_list_calendar_connections_for_sync(text,text,uuid) from anon, authenticated;
revoke execute on function public.site_save_calendar_connection(text,text,uuid,text,text,text,text,text,text,timestamptz,text) from anon, authenticated;
revoke execute on function public.site_record_calendar_shift_sync(text,text,uuid,uuid,timestamptz,timestamptz,jsonb,text,timestamptz,text) from anon, authenticated;
revoke execute on function public.site_disconnect_calendar_connection(text,text,uuid,uuid) from anon, authenticated;
revoke execute on function public.site_list_calendar_connections(text,text,uuid) from anon, authenticated;
revoke execute on function public.site_list_calendar_shifts(text,text,uuid) from anon, authenticated;
revoke execute on function public.site_start_new_draft(text,text,uuid,text) from anon, authenticated;
revoke execute on function public.schedule_list_calendar_shifts(text,text,uuid,uuid) from anon, authenticated;
revoke execute on function public.schedule_list_strand_test_occupancies(text,text,uuid,uuid) from anon, authenticated;
revoke execute on function public.schedule_record_strand_test_booking(text,text,uuid,uuid,uuid,uuid,text,uuid,timestamptz,timestamptz,text) from anon, authenticated;
-- resolve_login_email: revogar SOMENTE junto com o ajuste das rotas de login/cadastro.
```

**Ações complementares obrigatórias:** revogar e recriar o token OAuth do Google da conexão existente (deve-se assumir que vazou), e passar a cifrar os tokens em repouso (Vault/`pgsodium`) em vez de `text`.

### 3.4 Segredos vivos versionados no Git

`.project-config.json` está **commitado** desde `75a9983` e contém, em texto claro:

- senha de banco TiDB (`mysql://...root:<senha>@gateway03...tidbcloud.com`)
- `JWT_SECRET`
- `BUILT_IN_FORGE_API_KEY` e `VITE_FRONTEND_FORGE_API_KEY`
- token git `art_v2_x_...` (expirado em 14/08, mas o padrão permanece)

São credenciais da plataforma Manus, não do SaaS — o que reduz o impacto, **mas não elimina**. Pior: `scripts/guardrails.mjs` varre esse arquivo e **passa verde**, porque seus quatro regexes procuram `sb_secret_`, `service_role`, PEM e JWT `eyJ...`, e não pegam DSN com senha nem chaves opacas.

**Ação:** rotacionar tudo, remover o arquivo (é config de outro projeto, não pertence a este repositório), purgar do histórico e ampliar os padrões do guardrail.

### 3.5 JWT decodificado sem verificar assinatura

`owner-console-api/index.ts:39-54` e `scheduling-api` fazem apenas `atob` do payload do JWT para extrair o e-mail. Não validam assinatura, `exp`, `aud` nem `email_verified`. O comentário no código diz depender de `verify_jwt = true` no gateway — **mas `supabase/config.toml` não existe no repositório**, então esse controle não está versionado nem garantido. Um deploy com `--no-verify-jwt` transforma qualquer JWT forjado em acesso total ao tenant da vítima.

**Ação:** criar `supabase/config.toml` fixando `verify_jwt = true` por função **e** validar a assinatura dentro da função (defesa em profundidade).

---

## 4. O que está certo e não deve ser tocado

Isto é importante tanto quanto a lista de problemas — **você pediu para não mudar a estrutura do site, e concordo**.

| Ativo | Por que preservar |
|---|---|
| **Estrutura e navegação do configurador** | É o padrão certo: configurador na raiz, 14 módulos, entrada explícita para operação. Mantida como está. |
| **Honestidade do `configurator-real.tsx`** | Os 6 módulos com `ready:false` trazem `soonNote` explicando exatamente o que falta. É o artefato mais honesto do repositório e deve virar o padrão de todo o produto. |
| **Motor de agenda em SQL** | Exclusion constraints GiST, ledger unificado, holds idempotentes, snapshot com hash. Correto e difícil de fazer melhor. |
| **Versionamento de configuração** | `configuration_versions` imutável por trigger + `expectedRevision` (trava otimista). Resolve o problema de "alterar preço hoje reescreve o histórico de ontem". |
| **Webhook do WhatsApp** | HMAC-SHA256 com comparação em tempo constante, limite de payload, dedup por hash, persiste antes de responder `200`. Está conforme a documentação da Meta. |
| **Integração Google Calendar** | Única integração externa completa e funcionando. |
| **FKs compostas no núcleo** | `(tenant_id, id)` aplicado corretamente em toda a configuração e agenda. |
| **Qualidade documental** | A rotulagem "documentado, não implementado" é consistente e rara. Preserve esse rigor. |

**Confirmado nesta auditoria:** `pnpm lint`, `pnpm typecheck` e `pnpm test` passam (10, 10 e 11 tarefas, respectivamente).

---

## 5. O que está errado

| # | Problema | Consequência |
|---|---|---|
| E1 | **Três schemas rivais de WhatsApp/CRM** (`inbox_events` · `crm_*` · `contacts/messages`) | Duas ondas mortas no banco. Ninguém sabe qual é a verdade. Toda nova fatia escolhe errado. |
| E2 | **Motor de agenda testado ≠ motor executado** | `packages/scheduling-engine` (555 l., 17 testes) foi **copiado à mão** para `supabase/functions/scheduling-api/scheduling-engine.ts`. O próprio cabeçalho admite: *"os testes continuam rodando só contra o pacote original, não esta cópia"*. Os testes não protegem o código que roda. |
| E3 | **`/dashboard` exibe status inventado** | "Concluído", "verificação concluída", "persistência ativa" vêm de literais. É o que fez você perder a noção do estado real. |
| E4 | **15 tabelas com RLS e zero políticas** | Não é vazamento (é deny-all), mas significa que **todo o isolamento multiempresa dessas tabelas vive em código de aplicação**, não no banco. Combinado com `service_role` sem filtro, um bug numa Edge Function vira vazamento cross-tenant. |
| E5 | **9 FKs simples permitem cross-tenant no bloco CRM** | A pior é `campaign_recipients.consent_id → crm_contact_consents(id)`: o banco **não impede** que uma campanha do tenant A cite consentimento do tenant B. É exatamente a prova de opt-in que a LGPD e a Meta exigem. |
| E6 | **`apps/pilot-dashboard`** | 12.437 linhas que **não compilam** (sem `package.json`, sem `tsconfig`, importando pastas inexistentes). Contém telefone real, project ref hardcoded, e fallbacks que **retornam sucesso quando o insert falha**. |
| E7 | **`owner-console.test.ts`** | 6 testes que fazem `readFile` e `expect(source).toMatch(/auth\.getUser\(\)/)`. Dão falsa sensação de cobertura de segurança sem executar uma linha do app. |
| E8 | **Dois sistemas de autorização divergentes** | RPCs autorizam por `app.site_identities`; RLS autoriza por `app.tenant_memberships`. Mesmos dados, regras diferentes. `tenant_memberships` tem **0 linhas**. |
| E9 | **`app.conversations` tem `unique(tenant_id, contact_id)`** | Um contato **nunca** pode ter uma segunda conversa. Modelo errado para atendimento recorrente. |
| E10 | **CI aplica DDL em push de branch de feature** | Sem gate de aprovação, num banco compartilhado. E `g3-whatsapp-inbox-dev.yml` roda `pnpm install \|\| npm install` **sem instalar o pnpm** — sempre cai no `npm`, ignorando o lockfile. |
| E11 | **`main` e `dev` abandonados** | Todo o trabalho vive em `feature/saas-com-dashboard-completo`, que é a branch de produção da Vercel. Sem PR, sem revisão, sem histórico limpo. |
| E12 | **Sem ambiente local** | Não há `supabase/config.toml` nem seed. Toda validação roda contra o DEV compartilhado. |

---

## 6. O que vai quebrar se não corrigir

Ordenado por probabilidade × dano.

| # | O que quebra | Gatilho | Prazo |
|---|---|---|---|
| Q1 | **Conta Google do salão comprometida** | Qualquer pessoa que junte a trinca (§3.1) | **Já está exposto** |
| Q2 | **Vazamento cross-tenant de dados de clientes** | Segundo tenant entrar + um bug em Edge Function (não há RLS positiva de defesa) | No primeiro cliente pagante |
| Q3 | **Campanha enviada a quem não consentiu** | FK `consent_id` cross-tenant + sem opt-out implementado | No primeiro disparo real |
| Q4 | **Bloqueio do número pela Meta** | Campanha sem template `APPROVED`, sem opt-in rastreável, sem limite de frequência | No primeiro disparo real |
| Q5 | **Dupla reserva no mesmo recurso** | O motor testado não é o executado (E2); uma divergência entre as cópias não é detectada por teste | Quando o volume subir |
| Q6 | **Holds e sinais que nunca expiram** | `expire_stale_holds` é *lazy* (só varre na próxima escrita da mesma unidade) e `schedule_expire_due_deposits` **não tem agendador** | Já ocorre; invisível hoje por falta de volume |
| Q7 | **Perda de mensagem do WhatsApp** | A Meta reenvia por até 7 dias e depois **descarta — não há API para recuperar histórico**. Sem monitoramento do webhook, a perda é silenciosa e definitiva | No primeiro incidente de indisponibilidade |
| Q8 | **`next build` quebrado** | `research-next-build.md` documenta falha de prerender em `/_not-found` com diagnóstico **inconclusivo**. O gate `quality.yml` inclui `pnpm build` | A cada deploy |
| Q9 | **Impossível restaurar um desastre** | Backup nunca foi executado nem restaurado | No primeiro incidente |
| Q10 | **Embedded Signup v2 desligado** | A Meta **deprecia a v2 em 15/10/2026**. Onboarding multiempresa exige migrar para a v4 | Prazo fixo: 15/10/2026 |

---

## 7. Decisões de arquitetura que fecham as divergências

Essas seis decisões eliminam a causa de "andar em círculos". Precisam ser tomadas **antes** de escrever mais código.

| # | Decisão | Justificativa |
|---|---|---|
| **D1** | **O modelo de WhatsApp/CRM vencedor é a onda 1 + `crm_*` corrigido.** `app.inbox_events` continua sendo o log durável de entrada (é o único com chamador real e HMAC validado). As tabelas `crm_*` viram a **projeção legível**. As tabelas G3 (`contacts`, `conversations`, `messages`, `customer_consents`, `whatsapp_channels`) são **removidas por migração**, pois têm 0 linhas e 0 chamadores. | Preserva o único código que funciona; elimina 5 tabelas mortas; evita uma terceira reescrita. |
| **D2** | **O motor de agenda passa a ter fonte única.** O pacote `packages/scheduling-engine` deixa de existir como cópia; o build da Edge Function passa a **importar** o pacote (bundle no deploy). Os 17 testes passam a proteger o código executado. | Elimina a classe de bug mais perigosa do sistema. |
| **D3** | **`app.tenant_memberships` é a única fonte de autorização.** `app.site_identities` é migrado para membership e depois descontinuado. As RPCs passam a autorizar por `auth.uid()`. | Fim dos dois sistemas divergentes; e elimina a raiz da vulnerabilidade §3.1, que só existe porque a autorização aceita parâmetros do chamador. |
| **D4** | **Nenhuma tela exibe status que não venha do banco.** Todo indicador de prontidão é derivado de consulta. Onde não há dado, a tela diz "não configurado" — nunca "concluído". | É a correção do que te fez perder a noção de estado. |
| **D5** | **Orquestração assíncrona: `pgmq` + `pg_cron` dentro do Supabase.** O n8n **não** vira infraestrutura de produção; fica como orquestrador do piloto e de integrações periféricas. | Evita depender de uma VM Always Free para expiração de sinal, projeção de inbox e outbox de campanha — que são caminho crítico. |
| **D6** | **Modelo comercial otimiza para mensagem de utilidade, não de marketing.** No Brasil (2026), template de marketing custa ~R$ 0,31–0,38 e de utilidade ~R$ 0,04–0,05; resposta dentro da janela de 24 h é gratuita. | Confirmação/lembrete/remarcação (utilidade) são ~7× mais baratos que promoção. Isso define o produto **e** a margem. |

---

## 8. Plano por trilhas — fases que se complementam, não que se bloqueiam

Você pediu fases que não impeçam outras de acontecer. A estrutura abaixo é de **quatro trilhas paralelas** com pontos de sincronização. Só há uma dependência dura em todo o plano: **nada vai a cliente real antes da F0**.

```
F0 CONTENÇÃO  ██  (bloqueia tudo — 1 a 3 dias)
                 │
   ┌─────────────┼─────────────┬──────────────┐
   ▼             ▼             ▼              ▼
TRILHA A      TRILHA B      TRILHA C       TRILHA D
Fundação      Canal         Inteligência   Operação
              WhatsApp                     & Negócio
   │             │             │              │
  A1 convergir  B1 1ª msg     C1 gateway     D1 observabilidade
  A2 RLS+FKs    B2 inbox UI   C2 ag. cliente D2 LGPD
  A3 motor único B3 outbox    C3 ag. dona    D3 backup real
  A4 config.toml B4 templates C4 visão/STT   D4 piloto William
  A5 limpeza    B5 campanhas                 D5 precificação
```

### F0 — Contenção (1 a 3 dias) · **única fase bloqueante**

| ID | Entrega | Evidência de conclusão |
|---|---|---|
| F0-01 | Revogar `anon`/`authenticated` das 10 RPCs seguras | `has_function_privilege('anon', …)` = `false` para as 10 |
| F0-02 | Corrigir `resolve_login_email`: rotas de login/cadastro passam a usar chave secreta; revogar `anon` | Login por CPF continua funcionando; grant revogado |
| F0-03 | Revogar e reemitir o token OAuth Google da conexão existente | Nova conexão ativa; token antigo inválido |
| F0-04 | Remover `.project-config.json`, rotacionar os 4 segredos, purgar do histórico | `git log -p` sem o segredo; guardrail ampliado detecta o padrão |
| F0-05 | Criar `supabase/config.toml` com `verify_jwt = true` por função | Arquivo versionado |
| F0-06 | Validar assinatura do JWT dentro de `owner-console-api` e `scheduling-api` | Teste com JWT forjado retorna 401 |
| F0-07 | Cifrar `access_token`/`refresh_token` em repouso | Coluna cifrada; RPC de sync não retorna token em claro |

### Trilha A — Fundação estrutural

| ID | Entrega | Evidência |
|---|---|---|
| A1 | Migração de convergência: remover as 5 tabelas G3; `crm_*` vira projeção de `inbox_events` (D1) | 5 tabelas removidas; worker de projeção com teste |
| A2 | `unique(tenant_id,id)` em `campaigns`, `crm_contact_consents`, `calendar_connections`, `inbox_events`; converter as 9 FKs simples em compostas | Teste negativo: FK cross-tenant falha |
| A3 | Políticas RLS de SELECT por tenant nas 15 tabelas mudas + `FORCE` uniforme nas 27 | Suíte de isolamento cross-tenant passa |
| A4 | Fonte única do motor de agenda (D2) | `scheduling-engine.ts` deixa de ser cópia; 17 testes cobrem o código executado |
| A5 | Migrar `site_identities` → `tenant_memberships`; RPCs autorizam por `auth.uid()` (D3) | Nenhuma RPC aceita `email`/`tenant_id` como parâmetro de autorização |
| A6 | Remover `apps/pilot-dashboard`, `client/`, `apps/api`, `apps/worker` (stubs) | Repositório sem código morto; CI mais rápido |
| A7 | Substituir os 6 grep-tests por testes de comportamento das rotas | Cobertura real das 6 rotas `/api/` |
| A8 | `pgmq` + `pg_cron`: filas `inbox_projection`, `campaign_delivery`, `deposit_expiration` (D5) | Falha induzida gera DLQ e replay idempotente |
| A9 | Corrigir `unique(tenant_id, contact_id)` de `conversations` | Contato com 2 conversas é possível |
| A10 | Governança de branch: `main` protegida, PR obrigatório, CI sem DDL automático em feature | PR template + branch protection ativos |

### Trilha B — Canal WhatsApp

| ID | Entrega | Evidência |
|---|---|---|
| **B1** | **Primeira mensagem real ponta a ponta** | `app.inbox_events` com ≥1 linha vinda de um envio real ao número do piloto |
| B2 | Worker de projeção inbox → `crm_*` | Reentrega da Meta não duplica mensagem |
| B3 | Inbox operacional: conversa, direção, status, responsável, assumir/liberar | Tela lê projeção, isolada por tenant |
| B4 | Pausa por conversa / canal / unidade / tenant + parada de emergência | Durante a pausa, nenhuma resposta sai; motivo visível |
| B5 | Outbox de envio com idempotência e status da Meta | Retentativa não envia duas vezes |
| B6 | Sync de templates (nome, idioma, categoria, status, qualidade) | Template sem `APPROVED` é bloqueado antes do outbox |
| B7 | Mídia: áudio (STT) e imagem, assíncronos, com falha tratada | Erro não perde mensagem nem inventa transcrição |
| B8 | Embedded Signup **v4** (multiempresa) — prazo 15/10/2026 | Segundo tenant conecta o próprio número sem intervenção |

### Trilha C — Inteligência

| ID | Entrega | Evidência |
|---|---|---|
| C1 | Gateway de ferramentas tipadas com allowlist, schema, política e `correlation_id` | Prompt malicioso não aciona ferramenta fora do contrato; tentativa auditada |
| C2 | Agente da cliente — ferramentas de **leitura**: catálogo, cotação, disponibilidade, política | Resposta usa fato do motor; nunca inventa preço/horário |
| C3 | Agente da cliente — ferramentas de **escrita**: hold, solicitação de reserva | Nenhuma mutação sem estado/política correspondente |
| C4 | Handoff determinístico: química, imagem, pagamento, preço sem regra, baixa confiança, reclamação | Cada gatilho abre fila humana e bloqueia automação |
| C5 | Agente da proprietária: plano → prévia de impacto → confirmação versionada → auditoria | "Avise as clientes" lista destinatárias antes de enviar; editar invalida aprovação |
| C6 | Visão e STT com confiança, revisão humana e retenção curta | Baixa confiança não fecha preço nem química |
| C7 | Avaliação contínua: casos dourados, regressão, custo por conversa | Painel de qualidade e custo por fluxo |

### Trilha D — Operação e negócio

| ID | Entrega | Evidência |
|---|---|---|
| D1 | Observabilidade: atraso de webhook, erro por integração, fila pendente, custo de IA por tenant | Alertas ativos; falha induzida dispara alerta |
| D2 | LGPD executável: retenção por tipo de dado, exportação, eliminação, anonimização | Fluxo do titular testado com mídia e mensagens |
| D3 | Backup **executado e restaurado** em destino limpo | Restauração com checksum registrada |
| D4 | Piloto William com métricas e runbooks | Taxa de erro, handoff, confirmação, tempo de resposta |
| D5 | Precificação a partir de custo medido (D6) | Ledger de mensagens por categoria + custo de IA por conversa |
| D6 | Provisionar projeto Supabase de **produção** e pipeline de migração | PROD deixa de estar `INACTIVE`; CI aplica migrations com aprovação |

### Ponto de sincronização — critérios para o piloto real com William

O piloto só abre para clientes reais quando **todos** forem verdade:

1. F0 completa;
2. B1 comprovado (mensagem real no banco);
3. A2 e A3 completos (isolamento provado por teste negativo);
4. B4 (pausa de emergência funcionando);
5. C4 (handoff bloqueando química e preço sem regra);
6. D3 (backup restaurado ao menos uma vez);
7. Allowlist restrita ao seu número.

---

## 9. Catálogo completo de configuração do agente

Você pediu **todas as configurações possíveis, destrinchadas**. Esta seção é o mapa do que precisa existir para o agente ser inteligente o suficiente para cruzar dados e acertar.

A regra que organiza tudo: **a IA interpreta e redige; a configuração decide.** Cada item abaixo é um dado que, se faltar, obriga o agente a perguntar ou escalar — nunca a inventar.

### 9.1 Negócio e identidade
| Configuração | Consumido por | Se faltar |
|---|---|---|
| Nome, segmento, fuso horário, endereço, unidades | Tudo | Bloqueia publicação |
| Papéis e permissões (proprietária, gerente, profissional, recepção) | Autorização, aprovação de campanha | Ação sem papel é negada e auditada |
| Modo de operação (sozinha / equipe) | Motor de agenda | Muda o cálculo de capacidade |

### 9.2 Equipe e capacidade
| Configuração | Detalhe | Se faltar |
|---|---|---|
| Faixas semanais múltiplas | Ter–sex 9–18h **e** sáb 8–18h; turnos quebrados (9–12h, 13–18h) | Agenda oferece horário inexistente |
| Modo de disponibilidade | **Fixa** · **Híbrida** · **Dinâmica por evento confirmado** | Assistente ocasional entra no cálculo indevidamente |
| Turnos dinâmicos por data | Início e fim reais do plantão | Sábado cheio não abre vaga |
| Habilidades + qualificadores | ex.: `Coloração:Vermelho` | `NO_QUALIFIED_MEMBER` |
| Substitutos permitidos por etapa | — | Ausência derruba o atendimento inteiro |
| Almoço fixo ou dinâmico | — | Horário oferecido em cima do almoço |

### 9.3 Recursos
Lavatório, cadeira, sala, secador, prancha, kit de proteção — com **tipo, capacidade e unidade**. Cada etapa declara quais consome e se **libera ou bloqueia** o recurso durante a pausa. Sem isso, duas clientes recebem o mesmo lavatório.

### 9.4 Catálogo de serviços
| Configuração | Detalhe |
|---|---|
| Serviço simples ou composto | Composto = **um** serviço vendável com etapas internas (lavagem e pausa não viram serviços separados) |
| Etapas ordenadas | Tipo, ordem, condição de entrada, duração, responsável, recursos, `blocking_mode` |
| Pausa que libera o profissional | Mantém a cadeira ocupada e libera a pessoa — **só se a ficha declarar** |
| Variações | Comprimento, densidade, textura, técnica, condição, data, unidade, profissional |
| Matriz de preço/duração | Retorna valor **ou** `AVALIAÇÃO_NECESSÁRIA` — nunca um número inventado |
| Perfil técnico e pré-requisitos | Produto, instrução do fabricante, teste de mecha/alergia, EPI, ventilação, validade, severidade ao falhar |
| Versionamento | `service_version` imutável após publicada; a execução guarda qual versão foi realizada |

### 9.5 Agenda e políticas
| Configuração | Detalhe |
|---|---|
| Expediente e **término máximo** | Se fecha às 19h, nenhum procedimento pode **terminar** depois |
| Exceções autorizadas | Escopo (cliente/serviço/profissional/data), motivo, aprovador — ex.: sábado às 7h |
| Preparo vinculado | Teste de mecha: duração, antecedência mínima, dias permitidos, impacto na capacidade |
| **Precedência de regras** | 1) bloqueio legal/segurança · 2) regra individual da cliente · 3) exceção aprovada · 4) regra do serviço · 5) regra do período · 6) regra geral. **Conflito não resolvido bloqueia a confirmação e chama uma pessoa.** |
| Sinal | Por cliente / serviço / período; valor, prazo, confirmação verificável, expiração |
| Cancelamento, remarcação, atraso, no-show, reembolso | Cada um com janela e consequência |
| Google Calendar | OAuth por tenant, calendário por pessoa/recurso, `syncToken` incremental, tratamento de **410 Gone** (re-sync completo), canais `watch` com renovação |

### 9.6 Comunicação e WhatsApp
| Configuração | Detalhe |
|---|---|
| Tom da marca e regra "resolver antes de responder" | Uma pergunta objetiva por vez |
| Mensagens por evento | Confirmação, sinal, lembrete, remarcação, cancelamento, ausência, pós-atendimento |
| Transferência humana | Telefone/fila, horário de cobertura, gatilhos |
| WABA, número, `phone_number_id` | Mapeados ao tenant; token no cofre, **nunca** no banco de domínio |
| Templates | Nome, idioma, **categoria** (marketing/utilidade/autenticação), status, qualidade |
| Janela de 24 h | Fora dela, só template aprovado — sem texto livre como substituto |
| Allowlist do piloto | Restringe a números autorizados |
| Pausa | Por conversa, canal, unidade, tenant + parada global de emergência |

### 9.7 Cliente, CRM e conhecimento
| Configuração | Detalhe |
|---|---|
| Perfil descritivo de cabelo | Padrão de forma, comprimento, densidade, espessura, porosidade, condição, cor/técnica, histórico químico — **taxonomia do tenant**, nunca classificação racial |
| Proveniência do dado | Informado · inferido · revisado. Um atributo extraído de foto **não** sobrescreve o revisado por profissional |
| Consentimento por finalidade e canal | `TRANSACTIONAL` vs `MARKETING`, com evidência, data, origem e revogação |
| Fotos | Consentimento específico, finalidade, retenção, remoção comprovável |
| Referências visuais | Faixas de preço/duração e **nível de confiança** por referência |
| Janela de retorno sugerida | Por serviço/variação: início, tolerância, oferta permitida, exceções. Deriva de atendimento **executado**, não agendado |

### 9.8 Promoções e campanhas
Vigência · serviços elegíveis · benefício · exclusões · vagas · segmentação (recência, frequência, serviço, unidade, consentimento) · **justificativa por cliente** (por que entrou / por que saiu) · limite de frequência · opt-out · template aprovado · aprovação humana da versão exata do público congelado.

### 9.9 Configuração da própria IA
| Configuração | Detalhe |
|---|---|
| Modelo e versão do prompt | Versionados e auditados por decisão |
| Allowlist de ferramentas | `get_service_quote`, `find_available_slots`, `create_reservation_hold`, `get_client_history`, `build_campaign_preview`, `create_reschedule_plan` |
| Contexto mínimo por intenção | O modelo nunca recebe chave, SQL, documento inteiro ou dado de outro tenant |
| Limiares de confiança | Abaixo do limiar → handoff |
| Gatilhos de escalonamento obrigatório | Química, imagem, pagamento, preço sem regra, alteração de agenda, reclamação |
| Teto de custo por conversa/tenant | Alerta e corte |
| `store=false` e identificador de segurança hasheado | Já aplicado em `interpret-booking-intent` — manter |

---

## 10. n8n — caminho de configuração e fluxos

### 10.1 Papel do n8n (decisão D5)

O n8n é **orquestrador do piloto e de integrações periféricas**. Ele **não** é o CRM, o banco, a autorização, nem a interface. E **não** entra no caminho crítico: projeção de inbox, expiração de sinal e outbox de campanha ficam em `pgmq` + `pg_cron` no Supabase, porque não podem depender de uma VM Always Free.

**Regra inegociável:** a Meta **nunca** aponta para o n8n. O callback da Meta termina no webhook do SaaS, que valida a assinatura, persiste e responde `200`. Só depois um evento interno assinado chama o n8n. Se o n8n cair, o evento fica pendente e é reprocessado — a queda não vira perda de conversa.

### 10.2 Provisionamento, passo a passo

| Passo | Ação | Evidência de conclusão |
|---|---|---|
| N1 | Criar conta Oracle Cloud e VM ARM Always Free (**exige seus dados pessoais — só você pode fazer**) | VM acessível |
| N2 | Subdomínio + DNS + TLS (ex.: `n8n.eddigital.ia.br`) | Certificado válido |
| N3 | Docker Compose: n8n + PostgreSQL dedicado + proxy reverso (Caddy/Nginx) | Healthcheck; reinício preserva execuções |
| N4 | Endurecer: porta 5678 **nunca** exposta; só HTTPS via proxy; login único de administradora; `N8N_PROXY_HOPS` correto | `nmap` sem porta administrativa aberta |
| N5 | Variáveis: `N8N_ENCRYPTION_KEY` (segredo longo, guardado fora do servidor), `N8N_HOST`, `N8N_PROTOCOL=https`, `WEBHOOK_URL`, `N8N_SECURE_COOKIE=true`, `N8N_PAYLOAD_SIZE_MAX` | Manifesto versionado **sem valores** |
| N6 | Contrato de evento assinado SaaS → n8n: HMAC + `event_id` + `correlation_id` + expiração curta | Teste de assinatura inválida, evento expirado e `tenant_id` divergente → rejeitado |
| N7 | Backup do banco do n8n + export de workflows **sem credenciais** | Restauração testada em destino limpo |

### 10.3 Fluxos do piloto

**Fluxo 1 — Triagem e proposta (o principal)**

```
Evento interno assinado
  → valida assinatura, expiração e tenant
  → busca contexto mínimo no backend (mensagem, últimas N relevantes,
    estado da conversa, catálogo publicado, políticas)
  → classificador determinístico de risco
      ├─ risco alto → HANDOFF_REQUIRED → fila humana → FIM
      └─ risco baixo ↓
  → IA propõe texto + intenção estruturada (nunca executa ação)
  → backend valida a proposta contra schema e política
  → no piloto: toda 1ª resposta da conversa e toda ação de agenda
    exigem aprovação humana
  → grava em action_outbox com chave idempotente
  → envio pelo SaaS (não pelo n8n)
```

Gatilhos de `HANDOFF_REQUIRED`: química, imagem, pagamento, alteração de agendamento, preço sem regra publicada, baixa confiança, sentimento de reclamação, pedido explícito de humano.

**Fluxo 2 — Consulta de disponibilidade.** Recebe intenção + variáveis → chama `find_available_slots` (contrato autenticado do backend) → devolve **apenas** horários que o motor retornou. O n8n não calcula agenda.

**Fluxo 3 — Pedido de reserva.** Cria *hold* temporário via contrato do backend → devolve confirmação pendente. **Confirmação, sinal e qualquer alteração permanecem no SaaS.**

**Fluxo 4 — Notificação de falha.** Erro de integração, DLQ ou fila crescendo → alerta para você.

### 10.4 Limites que disparam saída do n8n

O Community Edition serve **uma administradora**. Entram como gatilho de reavaliação: múltiplos operadores, credenciais por cliente, necessidade de permissões/SAML, ou segundo tenant em produção. E revise a **licença de uso sustentável** antes de expor o editor a um cliente ou hospedar instância em nome de terceiros — esta arquitetura **não** expõe o editor ao William.

---

## 11. Matriz de evidência — a definição de "pronto"

Nenhum item é concluído sem os sete critérios. Esta é a regra que impede a repetição do ciclo.

| # | Critério |
|---|---|
| 1 | **Visível** — acessível na interface, não escondido |
| 2 | **Editável** — criar, editar, inativar e excluir de verdade |
| 3 | **Persistente** — sobrevive a recarga e a outro dispositivo |
| 4 | **Aplicado ao motor** — muda o comportamento da regra que o consome |
| 5 | **Falha tratada** — erro tem mensagem compreensível e estado seguro |
| 6 | **Testado** — teste automatizado do caminho feliz **e** do crítico |
| 7 | **Rotulado** — simulação · sandbox conectado · produção testada com evento real |

**Regra adicional, derivada do que deu errado:** um teste que lê o código-fonte (`expect(source).toMatch(...)`) **não** satisfaz o critério 6. E um relatório que comprova existência de tabela **não** satisfaz o critério 4.

---

## 12. Métricas, custo e modelo comercial

### 12.1 O que instrumentar desde o primeiro módulo
Conversas resolvidas vs. handoff · cotação → reserva · reserva → execução · cancelamento e no-show · retorno elegível → campanha aprovada → agendamento · opt-out · erro por integração · confiança visual · **custo de IA por conversa** · mensagens por categoria.

### 12.2 Custo variável do WhatsApp no Brasil (2026)

| Categoria | Custo aproximado | Uso no produto |
|---|---|---|
| Serviço (dentro da janela de 24 h) | **Gratuito** | Toda conversa iniciada pela cliente |
| Utilidade | ~R$ 0,04–0,05 | Confirmação, lembrete, remarcação, sinal |
| Marketing | ~R$ 0,31–0,38 | Promoção e reativação |
| Autenticação | ~R$ 0,15–0,19 | Não usado |

**Implicação de produto (D6):** o valor recorrente vem de utilidade e da janela gratuita — ~7× mais barato que marketing. Campanha promocional é o item de maior custo e maior risco (bloqueio, LGPD, reputação), e deve ser vendida como recurso controlado, não como carro-chefe.

### 12.3 Referências de retenção para o modelo

Churn mensal saudável em SaaS para PME fica em ~2–4%. **70% do churn acontece nos primeiros 90 dias**, e time-to-first-value abaixo de 7 dias reduz churn pela metade. Contrato anual suprime churn em 40–60% frente ao mensal.

**Tradução para o seu produto:** o onboarding — que aqui significa *configurar o agente* — é o produto. Um salão que não termina a configuração não ativa, e não ativando, cancela. Isso reforça por que a seção 9 é a parte mais importante deste plano: **o configurador é o motor de retenção**, não uma tela acessória.

### 12.4 O que ainda não dá para calcular
Não há cliente pagante, volume de mensagens, sessões de IA, custo de storage nem provedor de pagamento escolhido. Qualquer CAC, LTV, prazo de lucro ou preço final agora seria ficção. O item D5 existe para produzir esses números a partir de uso real do piloto.

---

## 13. Decisões que preciso de você

Estas travam o próximo passo e não posso tomar sozinho:

1. **Aplico a contenção F0 agora?** Os 10 revokes são seguros e verificados. Autorizo aplicar em seguida no DEV e abrir PR.
2. **Confirma D1** (remover as 5 tabelas G3, com 0 linhas e 0 chamadores, e manter `inbox_events` + `crm_*`)?
3. **Confirma D5** (`pgmq`/`pg_cron` no caminho crítico; n8n como periférico)?
4. **Provedor de pagamento para o sinal** — Mercado Pago, Asaas, Stripe? Define a integração do item D5/AGD-06.
5. **Política de retenção** para fotos, histórico químico, mensagens e auditoria (prazos por tipo).
6. **Recorte comercial do MVP**: salão, studio ou ambos no primeiro lançamento?

---

## 14. O que eu recomendo fazer nesta semana

| Dia | Ação |
|---|---|
| 1 | F0-01 a F0-04 — fechar a exposição e rotacionar segredos |
| 2 | F0-05 a F0-07 — `config.toml`, assinatura de JWT, cifrar tokens |
| 3 | **B1** — enviar uma mensagem real ao número do piloto e provar que ela chega em `app.inbox_events`. É o teste mais barato e mais informativo disponível |
| 4–5 | A1 + A2 — migração de convergência e correção das FKs cross-tenant |
| 5 | A10 — proteger `main`, exigir PR, tirar DDL automático do CI |

Depois disso, as quatro trilhas correm em paralelo e nenhuma trava a outra.

---

## Referências externas consultadas

- [Meta — Embedded Signup (Tech Provider)](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/overview/) — v2 depreciada em 15/10/2026; limite de 10 clientes por 7 dias, 200 após verificação
- [Meta — Webhooks](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview) — reenvio por até 7 dias; sem API de recuperação de histórico
- [Meta — Template fundamentals](https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview) — só template `APPROVED` fora da janela de 24 h
- [Google Calendar — Synchronize resources efficiently](https://developers.google.com/workspace/calendar/api/guides/sync) — `syncToken` e tratamento de `410 Gone`
- [Google Calendar — Push notifications](https://developers.google.com/workspace/calendar/api/guides/push) — canais `watch` e expiração
- [Supabase — Queues (`pgmq`)](https://supabase.com/docs/guides/queues) · [Cron](https://supabase.com/docs/guides/cron) · [Scheduling Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions)
- [n8n — Queue mode](https://docs.n8n.io/hosting/scaling/queue-mode/) · [Licença de uso sustentável](https://docs.n8n.io/privacy-and-security/sustainable-use-license/)
- [Anvisa — Produtos alisantes e ondulantes](https://www.gov.br/anvisa/pt-br/comunicacao/campanhas/estetica/produtos-alisantes-e-ondulantes-para-cabelo)
