# Regras do projeto (definidas pela Duda, dona do produto)

## Ambientes — regra de ouro

| Branch git | Projeto Supabase                             | Para quê                                                                                                  |
| ---------- | -------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `dev`      | **beleza-DEV** (`dboygmtrzgsfcmoquegp`)      | Onde tudo é construído e TESTADO: migrações, funções, salões-robô, clientes simuladas, testes com a Duda. |
| `main`     | **beleza-PRODUCAO** (`hjghwryhphgusefyivbl`) | O que está valendo, com clientes reais. Só recebe o que já passou no DEV. Espelho do DEV.                 |
| `world`    | —                                            | Não mexer.                                                                                                |

- **Nunca testar em produção.** Inconsistência se resolve no DEV, depois sobe.
- Não criar branch nova: o trabalho vai para `dev`. Produção só via `dev → main`.
- Mudança direta em produção só em conserto urgente, e com aviso à Duda antes.
- O número de WhatsApp **+55 16 99412-7035** é da PRODUÇÃO (tem dados de clientes). No DEV
  testa-se com o WhatsApp simulado (`channel_connections.simulado`) ou com número de teste da Meta.
- Dados de clientes (conversas, fotos, telefones, fichas) **não** vão para o DEV (LGPD). Para o
  DEV vai só configuração de salão (serviços, equipe, horários, regras, régua) e dados de teste.

## Como trabalhar

- Responder à Duda **sempre em português**, curto, passo a passo, com honestidade brutal.
- Antes de dizer "funciona", testar e mostrar a prova (o que ficou gravado no banco).
- Migração: aplicar no DEV, salvar em `supabase/migrations/<versão>_<nome>.sql` com o md5 igual ao
  aplicado. Função SECURITY DEFINER nova: `revoke ... from public, anon, authenticated` no mesmo arquivo.
- Deploy de edge function: uma função por execução do workflow e conferir o código no ar depois.
