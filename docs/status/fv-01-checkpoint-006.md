# FV-01 — Checkpoint 006: configurador real no DEV

Data: 2026-08-04  
Status: **DEPLOYED_DEV** — leitura E2E aprovada; primeira gravação pela interface pendente

## Resultado entregue

- O configurador do Sites está em acesso proprietário e permite somente a conta eddigital.oficial@gmail.com.
- Os tenants DEV Salão do William e Studio da Jack existem no projeto Supabase São Paulo e estão vinculados à identidade proprietária do Sites.
- A persistência normalizada cobre unidade, fuso, expediente, último término, competências, equipe, disponibilidade, recursos, capacidade, serviços, variações, etapas, requisitos, prontidão e publicação imutável.
- Sinal de pagamento permanece estruturalmente desativado.
- Google Agenda e WhatsApp não aparecem como conectados e permanecem fora do fluxo até os gates do motor de disponibilidade.

## Segurança e arquitetura

- A página exige Sign in with ChatGPT.
- Toda chamada do navegador passa pela rota server-side /api/configuration.
- A rota usa a identidade autenticada do Sites.
- A Edge Function site-configurator-api valida um segredo compartilhado antes de chamar RPCs exclusivas de service_role.
- O segredo está armazenado como secreto no Sites e no Supabase DEV; não existe no navegador nem no Git.
- A identidade é mapeada por projeto Sites, e-mail normalizado e tenant.
- Supabase Security Advisor: zero lints.

## Evidências

- Edge Function site-configurator-api: versão 1, ACTIVE.
- Chamada sem segredo: HTTP 401.
- Chamada autenticada: 2 workspaces; William carregado em DRAFT, revisão 1.
- Sites source commit: 1827e0db43243a1174beca05c5707fa5adca3b42.
- Sites versão 11: implantada com sucesso.
- URL: https://configurador-agentes-beleza.eddigital-oficial.chatgpt.site
- Lint e build Vinext aprovados.
- Testes: 3/3 aprovados.
- Smoke transacional com rollback: salvar configuração completa, prontidão sem bloqueios e publicar versão imutável.
- Rollback confirmado sem deixar dados de teste.

## Limite de evidência

A revisão de segurança impediu um teste automatizado que substituiria persistentemente o draft real do William. A automação visual do navegador também não iniciou no runtime Windows. Portanto, a primeira gravação persistente pela interface publicada deve ser feita pela proprietária; não foi marcada como aprovada sem evidência.

## Próximo gate

1. Abrir a versão publicada com a conta proprietária.
2. Preencher dados reais de William ou Jack e clicar em Salvar no DEV.
3. Recarregar e confirmar persistência.
4. Completar readiness e publicar a primeira versão operacional.
5. Iniciar motor de disponibilidade, hold e simulador de concorrência.
