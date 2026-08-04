# Contribuição

## Branches

Crie branches a partir de `dev`:

- `feature/<modulo>-<descricao>`;
- `fix/<modulo>-<descricao>`;
- `refactor/<modulo>-<descricao>`.

`hotfix/*` nasce de `main` e precisa voltar para `dev`. Nenhuma alteração comum é enviada
diretamente a `main`.

## Commits

Use Conventional Commits:

```text
tipo(escopo): descrição curta no imperativo
```

Tipos aceitos: `feat`, `fix`, `refactor`, `docs`, `test` e `chore`.

## Pull request

O corpo deve declarar:

1. o que muda e por quê;
2. módulos afetados;
3. estado real: implementado, testado, conectado ou simulado;
4. comandos e resultados de validação;
5. relatório de QA ou `N/A — aguardando QA`.

PR para `main` exige evidência de QA. Migração destrutiva exige autorização explícita da
fundadora antes da execução.

## Gate local

```bash
corepack pnpm@11.20.0 quality
```

Não versione `.env`, URLs com senha, chaves privadas, `service_role`, dumps, bundles ou segredos
protegidos do kit de backup.
