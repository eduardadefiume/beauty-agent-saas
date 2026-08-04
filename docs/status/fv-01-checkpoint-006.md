# FV-01 — Checkpoint 006: configurador real no DEV

Data: 2026-08-04  
Status: **IN_PROGRESS** — versão do Sites salva, ainda não implantada

## Resultado entregue

- O configurador do Sites está em acesso proprietário (custom) e permite somente a conta eddigital.oficial@gmail.com.
- Os tenants DEV Salão do William e Studio da Jack existem no projeto Supabase São Paulo e estão vinculados à identidade proprietária do Sites.
- A persistência normalizada cobre:
  - unidade e fuso horário;
  - expediente e último término;
  - competências, equipe e disponibilidade;
  - tipos de recurso, itens e capacidade;
  - serviços, variações, etapas e requisitos;
  - mensagem final, prontidão e publicação imutável.
- Sinal de pagamento permanece estruturalmente desativado (deposit_enabled = false).
- Google Agenda e WhatsApp não aparecem como integrações conectadas e permanecem fora do fluxo até os gates do motor de disponibilidade.

## Segurança e arquitetura

- A página exige Sign in with ChatGPT.
- Toda chamada do navegador passa pela rota server-side /api/configuration.
- A rota resolve a identidade autenticada pelo header confiável do Sites.
- A Edge Function site-configurator-api valida um segredo servidor-a-servidor e só então chama RPCs concedidas a service_role.
- A identidade do Sites é mapeada explicitamente por site_project_id, e-mail normalizado e tenant.
- Nenhuma chave administrativa é enviada ao navegador.
- Supabase Security Advisor: zero lints após a política explícita exclusiva de service_role.

## Evidências

- Edge Function site-configurator-api: versão 1, ACTIVE.
- Sites source commit: 1827e0db43243a1174beca05c5707fa5adca3b42.
- Sites version: 11, salva e não implantada.
- Lint: aprovado.
- Build Vinext: aprovado; rotas / e /api/configuration.
- Testes: 3/3 aprovados (bloqueio sem autenticação, render autenticado e ausência de estado demo).
- Smoke transacional com rollback:
  - configuração completa do William;
  - prontidão sem bloqueios;
  - publicação imutável gerada;
  - rollback confirmado sem deixar dados de teste.

## Bloqueio atual

A revisão de segurança bloqueou a cópia do segredo compartilhado gerado para o Supabase DEV sem uma autorização específica do usuário para essa transferência. O segredo já está armazenado como secreto no ambiente do Sites, mas ainda não foi confirmado no Supabase. Por isso, a versão 11 não foi implantada.

## Próximo gate

1. Obter autorização explícita para armazenar o segredo compartilhado no Supabase DEV.
2. Testar list, load, save e publish pelo caminho real Sites → Edge Function → Supabase.
3. Implantar a versão 11 com acesso proprietário.
4. Reabrir a URL publicada, salvar dados reais de William e Jack e confirmar persistência após reload.
