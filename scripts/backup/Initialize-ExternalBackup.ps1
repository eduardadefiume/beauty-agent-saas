[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
  [Parameter(Mandatory)] [ValidatePattern('^[a-z]{20}$')] [string] $ProjectRef,
  [Parameter(Mandatory)] [ValidatePattern('^age1[0-9a-z]{20,}$')] [string] $AgeRecipient,
  [string] $ExternalRoot = 'E:\BeautyAgentSaaS',
  [string] $ExpectedVolumeLabel = 'BEAUTY-BACKUP'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Common.psm1') -Force

$root = Assert-ExternalBackupRoot -ExternalRoot $ExternalRoot -ExpectedVolumeLabel $ExpectedVolumeLabel
$configDirectory = Join-Path $root 'Config'
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

$databaseUrl = Read-Host 'Cole a Database URL do Supabase (não será exibida)' -AsSecureString
$connection = ConvertTo-DatabaseConnectionParts -SecureDatabaseUrl $databaseUrl
if (-not $connection.Host.EndsWith('.supabase.com', [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Host recusado: $($connection.Host). Use a URL oficial do projeto Supabase."
}
Assert-ConnectionMatchesProjectRef -Connection $connection -ProjectRef $ProjectRef

$secretPath = Join-Path $configDirectory "$Environment-database-url.clixml"
$databaseUrl | Export-Clixml -LiteralPath $secretPath

$config = [ordered]@{
  environment = $Environment
  projectRef = $ProjectRef
  expectedVolumeLabel = $ExpectedVolumeLabel
  ageRecipient = $AgeRecipient
  schemas = @('app', 'private', 'public')
}

$configPath = Join-Path $configDirectory "$Environment.json"
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

Write-Host "Configuração protegida criada em $configPath"
Write-Host 'A senha está protegida pelo DPAPI e só abre para este usuário neste Windows.'
