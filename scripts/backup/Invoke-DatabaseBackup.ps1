[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
  [string] $ExternalRoot = 'E:\BeautyAgentSaaS',
  [ValidateRange(7, 3650)] [int] $RetentionDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Common.psm1') -Force

$configBundle = Get-BackupRuntimeConfig -Environment $Environment -ExternalRoot $ExternalRoot
$config = $configBundle.Config
$root = Assert-ExternalBackupRoot -ExternalRoot $ExternalRoot -ExpectedVolumeLabel $config.expectedVolumeLabel
$pgDump = Resolve-RequiredCommand -Names @('pg_dump.exe', 'pg_dump')
$pgRestore = Resolve-RequiredCommand -Names @('pg_restore.exe', 'pg_restore')
$age = Resolve-RequiredCommand -Names @('age.exe', 'age')

$secureUrl = Import-Clixml -LiteralPath $configBundle.SecretPath
$connection = ConvertTo-DatabaseConnectionParts -SecureDatabaseUrl $secureUrl
Assert-ConnectionMatchesProjectRef -Connection $connection -ProjectRef $config.projectRef
$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$prefix = "beauty-agent-$Environment"
$targetDirectory = Join-Path $root "Backups\Database\$Environment"
New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

$plainDump = Join-Path $targetDirectory ".incomplete-$([guid]::NewGuid().ToString('N')).dump"
$encryptedDump = Join-Path $targetDirectory "$prefix-$timestamp.dump.age"
$savedPgEnvironment = @{}

foreach ($name in @('PGHOST', 'PGPORT', 'PGDATABASE', 'PGUSER', 'PGPASSWORD', 'PGSSLMODE')) {
  $savedPgEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
  $env:PGHOST = $connection.Host
  $env:PGPORT = $connection.Port
  $env:PGDATABASE = $connection.Database
  $env:PGUSER = $connection.User
  $env:PGPASSWORD = $connection.Password
  $env:PGSSLMODE = 'require'

  $dumpArguments = @('--format=custom', '--compress=9', '--no-owner', '--no-privileges', "--file=$plainDump")
  foreach ($schema in $config.schemas) {
    if ($schema -notmatch '^[a-z_][a-z0-9_]*$') {
      throw "Schema inválido na configuração: $schema"
    }
    $dumpArguments += "--schema=$schema"
  }

  & $pgDump @dumpArguments
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $plainDump -PathType Leaf)) {
    throw "pg_dump falhou com código $LASTEXITCODE."
  }

  $restoreListing = & $pgRestore '--list' $plainDump 2>&1
  if ($LASTEXITCODE -ne 0 -or $restoreListing.Count -eq 0) {
    throw "pg_restore não conseguiu validar o catálogo do dump. Código: $LASTEXITCODE."
  }

  Invoke-AgeEncryption -AgeCommand $age -Recipient $config.ageRecipient -InputPath $plainDump -OutputPath $encryptedDump
  Write-BackupEvidence -BackupPath $encryptedDump -Metadata @{
    kind = 'postgres-logical'
    environment = $Environment
    projectRef = $config.projectRef
    schemas = @($config.schemas)
    encrypted = $true
    integrityCheck = 'pg_restore --list'
    pgDumpVersion = (& $pgDump '--version') -join ' '
  }

  Remove-ExpiredBackupSets -Directory $targetDirectory -Prefix $prefix -RetentionDays $RetentionDays
  Write-Host "Backup concluído: $encryptedDump"
}
finally {
  if (Test-Path -LiteralPath $plainDump -PathType Leaf) {
    Remove-Item -LiteralPath $plainDump -Force
  }

  foreach ($name in $savedPgEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $savedPgEnvironment[$name], 'Process')
  }

  $connection = $null
  $secureUrl = $null
}
