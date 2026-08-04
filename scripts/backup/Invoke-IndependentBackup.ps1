[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('dev', 'prod')] [string] $Environment,
  [Parameter(Mandatory)] [string] $RepositoryPath,
  [string] $ExternalRoot = 'E:\BeautyAgentSaaS',
  [ValidateRange(7, 3650)] [int] $RetentionDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Invoke-DatabaseBackup.ps1') `
  -Environment $Environment `
  -ExternalRoot $ExternalRoot `
  -RetentionDays $RetentionDays

& (Join-Path $PSScriptRoot 'Invoke-GitBackup.ps1') `
  -Environment $Environment `
  -RepositoryPath $RepositoryPath `
  -ExternalRoot $ExternalRoot `
  -RetentionDays $RetentionDays
