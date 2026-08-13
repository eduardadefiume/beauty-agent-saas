# Referências — filas e jobs do Supabase

**Consultado em:** 13 de agosto de 2026  
**Uso:** fundamentar a arquitetura de projeção da inbox e entrega de campanhas em `arquitetura-dashboard-multiempresa.md`.

| Fonte | Evidência relevante | Decisão arquitetural derivada |
|---|---|---|
| [Scheduling Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions) | O Supabase hospedado suporta `pg_cron`; combinado com `pg_net`, ele permite invocar Edge Functions periodicamente. A documentação recomenda Vault para credenciais de chamada. | Workers Edge são chamados por cron; URL/chave ficam no Vault. |
| [Cron](https://supabase.com/docs/guides/cron) | Jobs podem executar SQL/funções ou HTTP; runs são registrados. A recomendação é até oito jobs concorrentes e duração de até dez minutos. | Lotes curtos, nomes estáveis, observabilidade de execução e sem concorrência descontrolada. |
| [Queues](https://supabase.com/docs/guides/queues) | Supabase Queues é baseado em Postgres/`pgmq`, com entrega durável, janela de visibilidade, arquivamento e controles de acesso. | Fila `inbox_projection` e `campaign_delivery` separam webhook, CRM e envio. |

> Estas fontes não substituem testes de carga, verificação do plano Supabase ou validação do projeto de produção. Elas sustentam somente a escolha de padrão técnico.
