# Backup externo e recuperação

## Estado real

`IMPLEMENTADO / NÃO EXECUTADO EM AMBIENTE REAL`.

O kit cria cópias criptografadas no HD externo, mas nenhuma execução real pode ser declarada
enquanto os projetos DEV/PROD não estiverem autorizados nesta conexão e os scripts não forem
executados no Windows que possui o volume `E:`.

## O que cada camada protege

| Camada        | Conteúdo                                                        | Destino                               | Limite                                                         |
| ------------- | --------------------------------------------------------------- | ------------------------------------- | -------------------------------------------------------------- |
| Migrations    | Schema, funções, grants e RLS versionados                       | GitHub                                | Não contém dados cadastrados                                   |
| Dump lógico   | Schemas `app`, `private` e `public`, incluindo dados de negócio | `E:\BeautyAgentSaaS\Backups\Database` | Não contém objetos do Supabase Storage                         |
| Git bundle    | Commits, branches, tags e objetos Git alcançáveis               | `E:\BeautyAgentSaaS\Backups\Git`      | Não contém alterações não commitadas                           |
| Backup nativo | Projeto PostgreSQL conforme o plano Supabase                    | Supabase                              | É removido junto com o projeto e não inclui objetos do Storage |

O Storage terá rotina própria quando entrar no escopo da FV correspondente. Criar buckets antes
dessa rotina exige novo gate de Segurança/LGPD.

## Política inicial

| Ambiente             | Dados permitidos          | Frequência                             | Retenção                             | RPO alvo | RTO alvo |
| -------------------- | ------------------------- | -------------------------------------- | ------------------------------------ | -------- | -------- |
| DEV                  | Somente dados sintéticos  | Diário após uso relevante              | 14 dias                              | 24 h     | 8 h      |
| PROD vazio           | Nenhum cliente            | Antes/depois de migration              | 30 dias                              | N/A      | 8 h      |
| PROD com piloto real | Dados mínimos autorizados | Diário + antes de migration destrutiva | 30 dias externos + nativo contratado | 24 h     | 8 h      |

PITR será reavaliado quando perder até 24 horas de agenda se tornar inaceitável.

## Pré-requisitos no Windows

1. Renomear o volume externo para `BEAUTY-BACKUP`.
2. Instalar PowerShell 7, PostgreSQL Client compatível com o servidor, Git e `age`.
3. Gerar uma identidade `age` fora do HD `E:`. Guardar a chave privada em cofre de senhas e em
   mídia de recuperação separada. Somente a chave pública `age1...` entra na configuração.
4. Obter, para cada projeto, o `project ref` e a Database URL oficial do Supabase.
5. Nunca salvar a URL ou a senha em `.env`, GitHub ou texto aberto.

## Inicialização por ambiente

No PowerShell, dentro do repositório:

```powershell
pwsh .\scripts\backup\Initialize-ExternalBackup.ps1 `
  -Environment dev `
  -ProjectRef '<PROJECT_REF_DEV>' `
  -AgeRecipient '<CHAVE_PUBLICA_AGE>'

pwsh .\scripts\backup\Initialize-ExternalBackup.ps1 `
  -Environment prod `
  -ProjectRef '<PROJECT_REF_PROD>' `
  -AgeRecipient '<CHAVE_PUBLICA_AGE>'
```

A Database URL é solicitada sem eco e protegida pelo DPAPI. O arquivo só pode ser aberto pelo
mesmo usuário no mesmo Windows. Em desastre, a senha do banco pode ser redefinida no Supabase;
a chave privada `age`, mantida separadamente, é o que recupera os dumps.

## Primeira execução manual

```powershell
pwsh .\scripts\backup\Invoke-IndependentBackup.ps1 `
  -Environment dev `
  -RepositoryPath 'E:\BeautyAgentSaaS\Repository'
```

O script recusa:

- destino fora de `E:`;
- volume com rótulo diferente;
- Git com alterações não commitadas;
- conexão fora de `*.supabase.com`;
- dump cujo catálogo não abre com `pg_restore --list`;
- arquivo que não pôde ser criptografado.

Arquivos temporários sem criptografia são removidos no bloco `finally`. Cada backup válido recebe
SHA-256 e manifesto JSON. A limpeza automática só remove conjuntos com nome esperado e idade
maior que a retenção.

## Verificação mensal

```powershell
pwsh .\scripts\backup\Test-BackupArchive.ps1 `
  -BackupPath 'E:\BeautyAgentSaaS\Backups\Database\prod\<ARQUIVO>.dump.age' `
  -AgeIdentityPath '<CAMINHO_DA_CHAVE_PRIVADA_EM_MIDIA_SEPARADA>'
```

Esse teste comprova hash, descriptografia e catálogo do dump; não cria banco local. Depois que
PROD receber dados reais, um teste trimestral adicional deverá restaurar a cópia em um projeto
Supabase remoto descartável, validar contagens e RLS e então eliminar o projeto com aprovação
explícita. Até essa evidência existir, recuperação completa permanece `NÃO TESTADA`.

## Agendamento

Somente agende depois de uma execução manual aprovada. A conta do Agendador de Tarefas deve ser
a mesma que criou o segredo DPAPI, e o HD precisa permanecer conectado. Um job que falha porque o
HD foi removido deve gerar alerta; execução silenciosa não conta como backup.
