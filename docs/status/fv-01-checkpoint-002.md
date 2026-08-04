# FV-01 — checkpoint 002

**Estado:** `IN_PROGRESS`  
**Rótulo:** kit de continuidade implementado e validado estaticamente; execução real bloqueada

**Data:** 04 de agosto de 2026

## Alterações

- Recuperação da baseline do checkpoint 001 pelo snapshot canônico.
- Kit Windows para dump lógico remoto de DEV/PROD no HD `E:`.
- Criptografia assimétrica `age`; nenhuma chave privada ou senha no repositório.
- Evidência SHA-256 e manifesto por arquivo.
- Retenção restrita a nomes e diretórios validados.
- Bundle Git externo com `git fsck` e `git bundle verify`.
- Verificação de dump sem banco local usando `pg_restore --list`.
- Guardrail capaz de rodar também em snapshot sem diretório `.git`.
- Documentos canônicos incorporados ao repositório.
- Fluxo Git `main`/`dev`/`feature` preparado no GitHub privado.

## Evidência local

| Verificação               | Resultado                 |
| ------------------------- | ------------------------- |
| Guardrails                | Aprovado                  |
| Validação estática do kit | Aprovada                  |
| ESLint                    | 10/10 workspaces          |
| TypeScript                | 10/10 workspaces          |
| Testes unitários          | 7 aprovados, 0 reprovados |
| Builds                    | 10/10 workspaces          |
| Prettier                  | Aprovado                  |

## Gate de QA

| Verificação             | Estado                 | Evidência/limite                                           |
| ----------------------- | ---------------------- | ---------------------------------------------------------- |
| Segredo versionado      | Aprovado estaticamente | Guardrails e exemplos sem credencial                       |
| Destino externo         | Aprovado no código     | Script recusa caminho fora de `E:` e valida rótulo         |
| Dump PostgreSQL         | Não executado          | Novos projetos Supabase não autorizados nesta conexão      |
| Criptografia real       | Não executada          | Exige `age` e chave pública no Windows da Duda             |
| Restauração de catálogo | Não executada          | Exige um dump real                                         |
| GitHub remoto           | Bloqueado              | Conta conectada não retorna repositórios autorizados       |
| RLS remoto              | Bloqueado              | Conexão Supabase ainda mostra apenas projetos `refeitorio` |

Nenhum item bloqueado pode ser chamado de concluído até haver log e hash de execução real.
