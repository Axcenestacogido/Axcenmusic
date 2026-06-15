#Requires -Version 5.1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile    = Join-Path $scriptDir ".env"
$compose    = Join-Path $scriptDir "docker-compose.windows.yml"

if (-not (Test-Path $envFile)) {
    Write-Host "[!!] No existe .env. Ejecuta primero install-windows.ps1" -ForegroundColor Yellow
    exit 1
}

$profiles = if ((Get-Content $envFile) -match "WEBQUEUE_PORT") { "--profile extras" } else { "" }
Write-Host "[>>] Iniciando Axcenmusic..." -ForegroundColor Cyan
& docker compose -f $compose --env-file $envFile @($profiles -split " " | Where-Object { $_ }) up -d
Write-Host "[OK] Listo. Navidrome en http://localhost:$(((Get-Content $envFile) -match 'ND_PORT=') -replace 'ND_PORT=','')" -ForegroundColor Green
