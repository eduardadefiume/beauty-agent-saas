# Beauty Agent SaaS

SaaS multiempresa de agente de IA para salões e outros negócios de beleza.

## Sobre o projeto

O piloto valida o fluxo `configurar → validar → publicar → simular → explicar`, usando o mesmo
modelo para estabelecimentos diferentes. Regras de agenda são determinísticas; a LLM não decide
disponibilidade, duração, preço ou confirmação.

O projeto está na `FV-01`. Google Calendar, WhatsApp e OpenAI permanecem `MOCK`; pagamento e sinal
estão fora do piloto.

## Estado real

| Módulo                 | Estado                     | Evidência/limite                               |
| ---------------------- | -------------------------- | ---------------------------------------------- |
| Monorepo               | Em revisão para `dev`      | 10 workspaces compilam                         |
| Contratos/domínio      | Em desenvolvimento         | 7 testes unitários aprovados                   |
| Motor de agenda        | Em desenvolvimento         | Compilador inicial de serviço simples/composto |
| Banco/RLS              | Migrado no Supabase DEV    | RLS cross-tenant e advisors aprovados          |
| Configurador web       | Não iniciado               | Página mínima sem edição/persistência          |
| Google/WhatsApp/OpenAI | `MOCK`                     | Nenhum evento real conectado                   |
| Backup externo         | Implementado estaticamente | Execução real no Windows/`E:` pendente         |

## Estrutura

```text
apps/
  api/                       API NestJS
  web/                       Interface Next.js
  worker/                    Processamento assíncrono
packages/
  contracts/                 Contratos compartilhados
  database/                  Portas de persistência
  domain/                    Primitivos e regras de domínio
  integrations/              Portas para provedores externos
  observability/             Logs e correlação
  scheduling-engine/         Motor determinístico de agenda
  test-kit/                  Fixtures e utilitários de teste
docs/
  canonical/                 Escopo, requisitos, domínio, arquitetura e backlog aprovados
  operations/                Runbooks operacionais
  status/                    Evidências e limites de cada checkpoint
scripts/
  backup/                    Backup externo criptografado
supabase/
  migrations/                Migrações versionadas
  tests/                     Testes remotos de banco/RLS
```

## Documentação canônica

Leia nesta ordem:

1. `docs/canonical/escopo-piloto-sem-sinal-v1.md`
2. `docs/canonical/requisitos-piloto-v1.md`
3. `docs/canonical/modelo-dominio-configurador-v1.md`
4. `docs/canonical/arquitetura-tecnica-piloto-v1.md`
5. `docs/canonical/backlog-tecnico-piloto-v1.md`

O runbook de continuidade está em `docs/operations/backup-and-recovery.md`. A avaliação do MCP\nexterno de WhatsApp está em `docs/decisions/adr-002-whatsapp-mcp-upstream-evaluation.md`.

## Pré-requisitos

- Node.js 24 ou superior;
- pnpm 11.20.0 via Corepack;
- projeto Supabase remoto exclusivo do SaaS;
- para backup no Windows: PowerShell 7, PostgreSQL Client, Git e `age`.

## Desenvolvimento

```bash
corepack pnpm@11.20.0 install --frozen-lockfile
corepack pnpm@11.20.0 quality
```

Banco local está fora da decisão atual. Migrações são validadas primeiro no Supabase DEV remoto:

```bash
supabase link --project-ref <PROJECT_REF_DEV>
supabase db push --dry-run
supabase db push
```

Nunca use projetos Supabase de outro produto. Nenhuma chave privilegiada pode usar o prefixo
`NEXT_PUBLIC_`.

## Fluxo Git

- `main`: produção; somente após QA e liberação explícita;
- `dev`: integração/homologação;
- `feature/*`: funcionalidade nova, derivada de `dev`;
- `fix/*`: correção, derivada de `dev`;
- `hotfix/*`: urgência derivada de `main`, sincronizada de volta em `dev`;
- `refactor/*`: reorganização sem mudança de comportamento.

Commits seguem `tipo(escopo): descrição curta`. Consulte `CONTRIBUTING.md` antes de abrir PR.

## Publicação

O fluxo é `feature/fix → PR para dev → QA → PR dev para main → produção`. Migration só chega a
PROD depois de passar por DEV, advisors, testes de RLS e evidência registrada.

## Modulo Adicional: Painel Operacional do Piloto William
Dashboard Caderno de Operacoes adicionado em apps/pilot-dashboard para acompanhamento do piloto.
