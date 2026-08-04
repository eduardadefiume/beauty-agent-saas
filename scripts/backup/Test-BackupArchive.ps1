[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })] [string] $BackupPath,
  [Parameter(Mandatory)] [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })] [string] $AgeIdentityPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Common.psm1') -Force

$age = Resolve-RequiredCommand -Names @('age.exe', 'age')
$pgRestore = Resolve-RequiredCommand -Names @('pg_restore.exe', 'pg_restore')
$resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
if (-not $resolvedBackup.EndsWith('.dump.age', [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'Este teste aceita somente backups PostgreSQL com extensão .dump.age.'
}
$expectedHashPath = "$resolvedBackup.sha256"

if (-not (Test-Path -LiteralPath $expectedHashPath -PathType Leaf)) {
  throw "Hash ausente: $expectedHashPath"
}

$expectedHash = ((Get-Content -LiteralPath $expectedHashPath -Raw).Trim() -split '\s+')[0]
$actualHash = (Get-FileHash -LiteralPath $resolvedBackup -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expectedHash.ToLowerInvariant() -ne $actualHash) {
  throw 'SHA-256 divergente. O arquivo foi alterado ou corrompido.'
}

$temporaryDump = Join-Path ([System.IO.Path]::GetDirectoryName($resolvedBackup)) ".restore-check-$([guid]::NewGuid().ToString('N')).dump"
try {
  & $age '--decrypt' '--identity' $AgeIdentityPath '--output' $temporaryDump $resolvedBackup
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao descriptografar o backup. Código: $LASTEXITCODE."
  }

  $listing = & $pgRestore '--list' $temporaryDump 2>&1
  if ($LASTEXITCODE -ne 0 -or $listing.Count -eq 0) {
    throw "Catálogo pg_restore inválido. Código: $LASTEXITCODE."
  }

  Write-Host "Arquivo íntegro e catálogo PostgreSQL legível: $resolvedBackup"
}
finally {
  if (Test-Path -LiteralPath $temporaryDump -PathType Leaf) {
    Remove-Item -LiteralPath $temporaryDump -Force
  }
}
