#Requires -Version 5.1
<#
.SYNOPSIS
    Arranca el editor de tags en masa (music-tag-web) y Lidarr.
    Ejecutar despues de install-windows.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-OK   { param([string]$T) Write-Host "  [OK] $T" -ForegroundColor Green  }
function Write-Info { param([string]$T) Write-Host "  [>>] $T" -ForegroundColor Cyan   }
function Write-Fail { param([string]$T) Write-Host "  [XX] $T" -ForegroundColor Red    }

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$composeFile = Join-Path $scriptDir "docker-compose.windows.yml"
$envFile     = Join-Path $scriptDir ".env"

if (-not (Test-Path $envFile)) {
    Write-Fail "No existe .env. Ejecuta primero install-windows.ps1"
    exit 1
}

Write-Host ""
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host "  #   AXCENMUSIC -- Tags + Lidarr Setup      #" -ForegroundColor Cyan
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host ""

# Leer carpeta de musica del .env
$MUSIC_DIR = "C:\Music"
$envLine = (Get-Content $envFile | Where-Object { $_ -match "^MUSIC_DIR=" }) | Select-Object -First 1
if ($envLine) { $MUSIC_DIR = ($envLine -replace "^MUSIC_DIR=","").Replace("/","\") }

# Crear carpeta de descargas para Lidarr
$downloadsDir = Join-Path $MUSIC_DIR "downloads"
if (-not (Test-Path $downloadsDir)) {
    New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
    Write-OK "Carpeta de descargas creada: $downloadsDir"
}

# Anadir variables al .env si no existen (ASCII)
$envContent = Get-Content $envFile -Raw
$changed = $false
if ($envContent -notmatch "MUSIC_TAG_PORT") {
    Add-Content $envFile "`nMUSIC_TAG_PORT=6677"
    $changed = $true
}
if ($envContent -notmatch "LIDARR_PORT") {
    Add-Content $envFile "`nLIDAR_PORT=8686"
    $changed = $true
}
$downloadsDocker = $downloadsDir.Replace("\", "/")
if ($envContent -notmatch "DOWNLOADS_DIR") {
    Add-Content $envFile "`nDOWNLOADS_DIR=$downloadsDocker"
    $changed = $true
}
if ($envContent -notmatch "^TZ=") {
    Add-Content $envFile "`nTZ=Europe/Madrid"
    $changed = $true
}
if ($changed) { Write-OK ".env actualizado con nuevas variables" }

# Arrancar contenedores
Write-Info "Arrancando music-tag-web (editor de tags)..."
& docker compose -f $composeFile --env-file $envFile --profile tags up -d
if ($LASTEXITCODE -ne 0) { Write-Fail "Error al arrancar music-tag-web"; exit 1 }

Write-Info "Arrancando Lidarr..."
& docker compose -f $composeFile --env-file $envFile --profile lidarr up -d
if ($LASTEXITCODE -ne 0) { Write-Fail "Error al arrancar Lidarr"; exit 1 }

# Esperar arranque
Write-Info "Esperando que los servicios arranquen (30 s)..."
Start-Sleep -Seconds 30

Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |   EDITOR DE TAGS + LIDARR LISTOS                   |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  EDITOR DE TAGS EN MASA (music-tag-web)             |" -ForegroundColor Green
Write-Host "  |    URL local : http://localhost:6677                 |" -ForegroundColor Green
Write-Host "  |    Funnel    : tailscale funnel --bg                 |" -ForegroundColor Green
Write-Host "  |                  --https=6643 http://localhost:6677  |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  Como usar:                                          |" -ForegroundColor Green
Write-Host "  |    1. Abre http://localhost:6677                     |" -ForegroundColor Green
Write-Host "  |    2. Selecciona varios archivos con Ctrl+clic       |" -ForegroundColor Green
Write-Host "  |    3. Edita artista, album, anio, caratula en masa  |" -ForegroundColor Green
Write-Host "  |    4. Guarda -- los tags se escriben en los archivos |" -ForegroundColor Green
Write-Host "  |    5. En Navidrome: Biblioteca -> Escanear ahora     |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  LIDARR (gestor de coleccion de musica)             |" -ForegroundColor Green
Write-Host "  |    URL local : http://localhost:8686                 |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  Primeros pasos en Lidarr:                          |" -ForegroundColor Green
Write-Host "  |    1. Abre http://localhost:8686                     |" -ForegroundColor Green
Write-Host "  |    2. Settings -> Media Management -> Root Folders   |" -ForegroundColor Green
Write-Host "  |       Anade: /music                                  |" -ForegroundColor Green
Write-Host "  |    3. Settings -> Download Clients -> anade          |" -ForegroundColor Green
Write-Host "  |       qBittorrent o cualquier cliente de descarga    |" -ForegroundColor Green
Write-Host "  |    4. Artist -> Add New Artist -> busca tu artista   |" -ForegroundColor Green
Write-Host "  |       y Lidarr descargara sus albums automaticamente |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""

Read-Host "  Pulsa ENTER para salir"
