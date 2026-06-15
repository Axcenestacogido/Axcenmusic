#Requires -Version 5.1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile    = Join-Path $scriptDir ".env"
$compose    = Join-Path $scriptDir "docker-compose.windows.yml"

Write-Host "[>>] Descargando imagen actualizada de Navidrome..." -ForegroundColor Cyan
& docker compose -f $compose --env-file $envFile pull
Write-Host "[>>] Reiniciando con la nueva version..." -ForegroundColor Cyan
& docker compose -f $compose --env-file $envFile up -d
Write-Host "[OK] Navidrome actualizado." -ForegroundColor Green
