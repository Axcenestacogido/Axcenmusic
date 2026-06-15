#Requires -Version 5.1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$compose   = Join-Path $scriptDir "docker-compose.windows.yml"

Write-Host "[>>] Parando Axcenmusic..." -ForegroundColor Cyan
& docker compose -f $compose --profile extras down
Write-Host "[OK] Servicios detenidos." -ForegroundColor Green
