Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExternalBackupRoot {
  param(
    [Parameter(Mandatory)] [string] $ExternalRoot,
    [Parameter(Mandatory)] [string] $ExpectedVolumeLabel
  )

  if ($env:OS -ne 'Windows_NT') {
    throw 'O kit de backup externo deve ser executado no Windows.'
  }

  $fullRoot = [System.IO.Path]::GetFullPath($ExternalRoot)
  if (-not $fullRoot.StartsWith('E:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Destino recusado: o caminho deve estar em E:\. Recebido: $fullRoot"
  }

  $volume = Get-Volume -DriveLetter E -ErrorAction Stop
  if ($ExpectedVolumeLabel -and $volume.FileSystemLabel -ne $ExpectedVolumeLabel) {
    throw "Volume E: incorreto. Esperado '$ExpectedVolumeLabel'; encontrado '$($volume.FileSystemLabel)'."
  }

  if ($volume.HealthStatus -ne 'Healthy') {
    throw "O volume E: não está saudável: $($volume.HealthStatus)."
  }

  New-Item -ItemType Directory -Path $fullRoot -Force | Out-Null
  return $fullRoot.TrimEnd('\')
}

function Resolve-RequiredCommand {
  param([Parameter(Mandatory)] [string[]] $Names)

  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) {
      return $command.Source
    }
  }

  throw "Comando obrigatório não encontrado: $($Names -join ' ou ')."
}

function Get-BackupRuntimeConfig {
  param(
    [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
    [Parameter(Mandatory)] [string] $ExternalRoot
  )

  $configPath = Join-Path $ExternalRoot "Config\$Environment.json"
  $secretPath = Join-Path $ExternalRoot "Config\$Environment-database-url.clixml"

  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Configuração ausente: $configPath. Execute Initialize-ExternalBackup.ps1 primeiro."
  }

  if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
    throw "Segredo protegido ausente: $secretPath. Execute Initialize-ExternalBackup.ps1 primeiro."
  }

  $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  if ($config.environment -ne $Environment) {
    throw "Ambiente da configuração diverge do solicitado: $($config.environment)."
  }

  if ($config.projectRef -notmatch '^[a-z]{20}$') {
    throw 'Project ref inválido na configuração.'
  }

  if ($config.ageRecipient -notmatch '^age1[0-9a-z]{20,}$') {
    throw 'Destinatário público age inválido na configuração.'
  }

  if (-not $config.schemas -or $config.schemas.Count -eq 0) {
    throw 'A configuração precisa declarar pelo menos um schema.'
  }

  return [pscustomobject]@{
    Config = $config
    ConfigPath = $configPath
    SecretPath = $secretPath
  }
}

function ConvertTo-DatabaseConnectionParts {
  param([Parameter(Mandatory)] [securestring] $SecureDatabaseUrl)

  $plainUrl = [System.Net.NetworkCredential]::new('', $SecureDatabaseUrl).Password
  try {
    $uri = [uri]$plainUrl
    if ($uri.Scheme -notin @('postgres', 'postgresql')) {
      throw 'A URL protegida não é uma conexão PostgreSQL.'
    }

    $userInfo = $uri.UserInfo -split ':', 2
    if ($userInfo.Count -ne 2) {
      throw 'A URL precisa conter usuário e senha.'
    }

    return [pscustomobject]@{
      Host = $uri.Host
      Port = if ($uri.IsDefaultPort) { '5432' } else { [string]$uri.Port }
      Database = $uri.AbsolutePath.TrimStart('/')
      User = [uri]::UnescapeDataString($userInfo[0])
      Password = [uri]::UnescapeDataString($userInfo[1])
    }
  }
  finally {
    $plainUrl = $null
  }
}

function Assert-ConnectionMatchesProjectRef {
  param(
    [Parameter(Mandatory)] [pscustomobject] $Connection,
    [Parameter(Mandatory)] [string] $ProjectRef
  )

  $connectionIdentity = "$($Connection.Host)|$($Connection.User)"
  if (-not $connectionIdentity.Contains($ProjectRef, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "A conexão não pertence ao project ref declarado: $ProjectRef."
  }
}

function Invoke-AgeEncryption {
  param(
    [Parameter(Mandatory)] [string] $AgeCommand,
    [Parameter(Mandatory)] [string] $Recipient,
    [Parameter(Mandatory)] [string] $InputPath,
    [Parameter(Mandatory)] [string] $OutputPath
  )

  & $AgeCommand '--recipient' $Recipient '--output' $OutputPath $InputPath
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw "A criptografia age falhou com código $LASTEXITCODE."
  }
}

function Write-BackupEvidence {
  param(
    [Parameter(Mandatory)] [string] $BackupPath,
    [Parameter(Mandatory)] [hashtable] $Metadata
  )

  $hash = Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256
  $hashPath = "$BackupPath.sha256"
  $manifestPath = "$BackupPath.manifest.json"

  "$($hash.Hash.ToLowerInvariant())  $([System.IO.Path]::GetFileName($BackupPath))" |
    Set-Content -LiteralPath $hashPath -Encoding utf8NoBOM

  $evidence = [ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    fileName = [System.IO.Path]::GetFileName($BackupPath)
    sizeBytes = (Get-Item -LiteralPath $BackupPath).Length
    sha256 = $hash.Hash.ToLowerInvariant()
  }

  foreach ($key in $Metadata.Keys) {
    $evidence[$key] = $Metadata[$key]
  }

  $evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
}

function Remove-ExpiredBackupSets {
  param(
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [string] $Prefix,
    [Parameter(Mandatory)] [ValidateRange(7, 3650)] [int] $RetentionDays
  )

  $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
  $pattern = "^$([regex]::Escape($Prefix))-\d{8}T\d{6}Z\.(?:dump|bundle)\.age$"

  Get-ChildItem -LiteralPath $Directory -File -Filter "$Prefix-*.age" |
    Where-Object { $_.Name -match $pattern -and $_.LastWriteTimeUtc -lt $cutoff } |
    ForEach-Object {
      $paths = @($_.FullName, "$($_.FullName).sha256", "$($_.FullName).manifest.json")
      foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          Remove-Item -LiteralPath $path -Force
        }
      }
    }
}

Export-ModuleMember -Function @(
  'Assert-ExternalBackupRoot',
  'Resolve-RequiredCommand',
  'Get-BackupRuntimeConfig',
  'ConvertTo-DatabaseConnectionParts',
  'Assert-ConnectionMatchesProjectRef',
  'Invoke-AgeEncryption',
  'Write-BackupEvidence',
  'Remove-ExpiredBackupSets'
)
