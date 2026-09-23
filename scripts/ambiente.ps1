# QUAL BANCO ESTA NA MIRA, E COMO TROCAR SEM ERRAR.
#
# 23/09/2026. Ate hoje existia um banco so, e ele se chamava
# "agente-beleza-saas-dev-sp" -- rodando a producao inteira. Um nome mentindo
# sobre o que a coisa e ja e um acidente esperando acontecer; dois bancos
# parecidos, sem nada na tela dizendo em qual voce esta, seria pior.
#
# O `supabase db push` nao pergunta para onde vai: ele usa o projeto que esta
# em supabase/.temp/project-ref, escrito pelo ultimo `link` que voce rodou --
# que pode ter sido ontem. Este script existe para essa pergunta ter resposta
# antes, e nao depois.
#
# COMO USAR
#   .\scripts\ambiente.ps1            ve onde voce esta
#   .\scripts\ambiente.ps1 dev        aponta para o DEV
#   .\scripts\ambiente.ps1 producao   aponta para a PRODUCAO (com confirmacao)
#
# O REPOUSO E O DEV, DE PROPOSITO. Depois de mexer na producao, volte para o
# dev. Assim um `db push` distraido cai no lugar barato.

param([string]$Alvo = '')

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$AMBIENTES = @{
  'dev'      = @{ ref = 'dboygmtrzgsfcmoquegp'; nome = 'DEV       (agente-beleza-saas-prod-sp)'; cor = 'Green' }
  'producao' = @{ ref = 'hjghwryhphgusefyivbl'; nome = 'PRODUCAO  (agente-beleza-saas-dev-sp)';  cor = 'Red'   }
}

function Mostrar-Atual {
  $arquivo = Join-Path $raiz 'supabase\.temp\project-ref'
  if (-not (Test-Path $arquivo)) {
    Write-Host "`n  Nenhum projeto ligado ainda.`n" -ForegroundColor Yellow
    return $null
  }
  $ref = (Get-Content $arquivo -Raw).Trim()
  $achado = $AMBIENTES.GetEnumerator() | Where-Object { $_.Value.ref -eq $ref }
  if ($achado) {
    Write-Host "`n  Voce esta em: " -NoNewline
    Write-Host $achado.Value.nome -ForegroundColor $achado.Value.cor
    Write-Host "  ref: $ref`n"
  } else {
    Write-Host "`n  ATENCAO: ref desconhecido ($ref). Nao e o dev nem a producao.`n" -ForegroundColor Yellow
  }
  return $ref
}

if ($Alvo -eq '') { Mostrar-Atual | Out-Null; exit 0 }

$chave = $Alvo.ToLower()
if (-not $AMBIENTES.ContainsKey($chave)) {
  Write-Host "`n  Alvo invalido. Use 'dev' ou 'producao'.`n" -ForegroundColor Yellow
  exit 1
}

$destino = $AMBIENTES[$chave]

# A producao pede que voce escreva o nome dela. Nao e burocracia: e o intervalo
# entre a distracao e o estrago.
if ($chave -eq 'producao') {
  Write-Host ""
  Write-Host "  Voce esta apontando para a PRODUCAO." -ForegroundColor Red
  Write-Host "  E o banco do salao do William, com o WhatsApp no ar."
  Write-Host ""
  $confirma = Read-Host "  Escreva PRODUCAO para continuar"
  if ($confirma -cne 'PRODUCAO') {
    Write-Host "`n  Cancelado. Nada mudou.`n" -ForegroundColor Green
    exit 0
  }
}

Write-Host "`n  Ligando em $($destino.nome)..." -ForegroundColor $destino.cor
Write-Host "  (se pedir a senha do banco, digite direto aqui)`n"

Push-Location $raiz
try {
  npx supabase link --project-ref $destino.ref
} finally {
  Pop-Location
}

Mostrar-Atual | Out-Null

if ($chave -eq 'producao') {
  Write-Host "  LEMBRE: quando terminar, volte com  .\scripts\ambiente.ps1 dev`n" -ForegroundColor Yellow
}
