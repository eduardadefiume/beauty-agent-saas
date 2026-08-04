[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
  [Parameter(Mandatory)] [string] $RepositoryPath,
  [string] $ExternalRoot = 'E:\BeautyAgentSaaS',
  [ValidateRange(7, 3650)] [int] $RetentionDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Common.psm1') -Force

$configBundle = Get-BackupRuntimeConfig -Environment $Environment -ExternalRoot $ExternalRoot
$config = $configBundle.Config
$root = Assert-ExternalBackupRoot -ExternalRoot $ExternalRoot -ExpectedVolumeLabel $config.expectedVolumeLabel
$git = Resolve-RequiredCommand -Names @('git.exe', 'git')
$age = Resolve-RequiredCommand -Names @('age.exe', 'age')
$resolvedRepository = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path

if (-not (Test-Path -LiteralPath (Join-Path $resolvedRepository '.git'))) {
  throw "Não é um repositório Git: $resolvedRepository"
}

$dirty = & $git '-C' $resolvedRepository 'status' '--porcelain=v1'
if ($LASTEXITCODE -ne 0) {
  throw 'Não foi possível consultar o estado do repositório.'
}
if ($dirty) {
  throw 'Backup Git recusado: existem alterações não commitadas. Faça commit ou descarte conscientemente antes.'
}

& $git '-C' $resolvedRepository 'fsck' '--full' '--no-dangling'
if ($LASTEXITCODE -ne 0) {
  throw 'git fsck encontrou corrupção; o bundle não será criado.'
}

$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$prefix = "beauty-agent-git-$Environment"
$targetDirectory = Join-Path $root 'Backups\Git'
New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
$plainBundle = Join-Path $targetDirectory ".incomplete-$([guid]::NewGuid().ToString('N')).bundle"
$encryptedBundle = Join-Path $targetDirectory "$prefix-$timestamp.bundle.age"

try {
  & $git '-C' $resolvedRepository 'bundle' 'create' $plainBundle '--all'
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $plainBundle -PathType Leaf)) {
    throw "git bundle create falhou com código $LASTEXITCODE."
  }

  & $git 'bundle' 'verify' $plainBundle
  if ($LASTEXITCODE -ne 0) {
    throw "git bundle verify falhou com código $LASTEXITCODE."
  }

  Invoke-AgeEncryption -AgeCommand $age -Recipient $config.ageRecipient -InputPath $plainBundle -OutputPath $encryptedBundle
  $head = (& $git '-C' $resolvedRepository 'rev-parse' 'HEAD').Trim()
  $branch = (& $git '-C' $resolvedRepository 'branch' '--show-current').Trim()
  $remote = (& $git '-C' $resolvedRepository 'remote' 'get-url' 'origin' 2>$null)

  Write-BackupEvidence -BackupPath $encryptedBundle -Metadata @{
    kind = 'git-bundle'
    environment = $Environment
    head = $head
    branch = $branch
    remoteConfigured = [bool]$remote
    encrypted = $true
    integrityCheck = 'git bundle verify'
  }

  Remove-ExpiredBackupSets -Directory $targetDirectory -Prefix $prefix -RetentionDays $RetentionDays
  Write-Host "Backup Git concluído: $encryptedBundle"
}
finally {
  if (Test-Path -LiteralPath $plainBundle -PathType Leaf) {
    Remove-Item -LiteralPath $plainBundle -Force
  }
}
