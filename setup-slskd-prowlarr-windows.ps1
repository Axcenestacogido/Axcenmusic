#Requires -Version 5.1
<#
.SYNOPSIS
    Arranca Homarr (dashboard unificado), slskd (Soulseek) y Prowlarr (indexadores).
    Ejecutar despues de install-windows.ps1 y setup-tags-lidarr-windows.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-OK   { param([string]$T) Write-Host "  [OK] $T" -ForegroundColor Green  }
function Write-Info { param([string]$T) Write-Host "  [>>] $T" -ForegroundColor Cyan   }
function Write-Warn { param([string]$T) Write-Host "  [!!] $T" -ForegroundColor Yellow }
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
Write-Host "  #  AXCENMUSIC -- Dashboard + Soulseek      #" -ForegroundColor Cyan
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host ""

# Leer datos del .env
$ND_PORT = "4533"; $WEBQUEUE_PORT = "8888"; $LIDARR_PORT = "8686"
$MUSIC_TAG_PORT = "6677"; $MUSIC_DIR = "C:\Music"
Get-Content $envFile | ForEach-Object {
    if ($_ -match "^ND_PORT=(.+)")          { $ND_PORT = $Matches[1] }
    if ($_ -match "^WEBQUEUE_PORT=(.+)")    { $WEBQUEUE_PORT = $Matches[1] }
    if ($_ -match "^LIDARR_PORT=(.+)")      { $LIDARR_PORT = $Matches[1] }
    if ($_ -match "^MUSIC_TAG_PORT=(.+)")   { $MUSIC_TAG_PORT = $Matches[1] }
    if ($_ -match "^MUSIC_DIR=(.+)")        { $MUSIC_DIR = $Matches[1].Replace("/","\") }
}

# Anadir variables nuevas al .env si faltan
$envContent = Get-Content $envFile -Raw
$changed = $false
@{
    "HOMARR_PORT"   = "7575"
    "SLSKD_PORT"    = "5030"
    "PROWLARR_PORT" = "9696"
    "TZ"            = "Europe/Madrid"
}.GetEnumerator() | ForEach-Object {
    if ($envContent -notmatch "^$($_.Key)=") {
        Add-Content $envFile "`n$($_.Key)=$($_.Value)"
        $changed = $true
    }
}
if ($changed) { Write-OK ".env actualizado" }

# Crear carpeta de descargas de Soulseek
$slskDir = Join-Path $MUSIC_DIR "soulseek"
if (-not (Test-Path $slskDir)) {
    New-Item -ItemType Directory -Force -Path $slskDir | Out-Null
    Write-OK "Carpeta Soulseek creada: $slskDir"
}

# Arrancar servicios
Write-Info "Arrancando Homarr (dashboard)..."
& docker compose -f $composeFile --env-file $envFile --profile dashboard up -d
if ($LASTEXITCODE -ne 0) { Write-Fail "Error al arrancar Homarr"; exit 1 }

Write-Info "Arrancando slskd (Soulseek)..."
& docker compose -f $composeFile --env-file $envFile --profile soulseek up -d
if ($LASTEXITCODE -ne 0) { Write-Fail "Error al arrancar slskd"; exit 1 }

Write-Info "Arrancando Prowlarr (indexadores para Lidarr)..."
& docker compose -f $composeFile --env-file $envFile --profile lidarr up -d
if ($LASTEXITCODE -ne 0) { Write-Fail "Error al arrancar Prowlarr"; exit 1 }

Write-Info "Esperando que los servicios arranquen (30 s)..."
Start-Sleep -Seconds 30

# Resumen
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |          TODOS LOS SERVICIOS LISTOS                 |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  DASHBOARD UNIFICADO (Homarr) -- EMPIEZA AQUI      |" -ForegroundColor Cyan
Write-Host "  |    http://localhost:7575                             |" -ForegroundColor Cyan
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  Desde Homarr accedes a todo con un clic:           |" -ForegroundColor Green
Write-Host "  |    Navidrome  -> http://localhost:$ND_PORT               |" -ForegroundColor DarkGray
Write-Host "  |    WebQueue   -> http://localhost:$WEBQUEUE_PORT               |" -ForegroundColor DarkGray
Write-Host "  |    Tags       -> http://localhost:$MUSIC_TAG_PORT               |" -ForegroundColor DarkGray
Write-Host "  |    Lidarr     -> http://localhost:$LIDARR_PORT               |" -ForegroundColor DarkGray
Write-Host "  |    Soulseek   -> http://localhost:5030               |" -ForegroundColor DarkGray
Write-Host "  |    Prowlarr   -> http://localhost:9696               |" -ForegroundColor DarkGray
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  CONFIGURAR HOMARR (5 min)                          |" -ForegroundColor Green
Write-Host "  |    1. Abre http://localhost:7575                     |" -ForegroundColor Green
Write-Host "  |    2. Clic en el lapiz (editar) abajo a la derecha  |" -ForegroundColor Green
Write-Host "  |    3. Add a service -> rellena nombre y URL         |" -ForegroundColor Green
Write-Host "  |       de cada servicio de arriba                    |" -ForegroundColor Green
Write-Host "  |    4. Guarda -- tienes tu panel personalizado        |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  EXPONER HOMARR POR TAILSCALE FUNNEL                |" -ForegroundColor Green
Write-Host "  |    tailscale funnel --bg http://localhost:7575       |" -ForegroundColor Green
Write-Host "  |    (reemplaza el funnel anterior de Navidrome)       |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  CONFIGURAR SOULSEEK (slskd)                        |" -ForegroundColor Green
Write-Host "  |    1. Abre http://localhost:5030                     |" -ForegroundColor Green
Write-Host "  |    2. Crea cuenta gratis en slsknet.org              |" -ForegroundColor Green
Write-Host "  |    3. En slskd: Settings -> Soulseek                 |" -ForegroundColor Green
Write-Host "  |       Usuario y contrasena de tu cuenta Soulseek    |" -ForegroundColor Green
Write-Host "  |    4. Busca musica -> descarga -> va a $slskDir" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  CONECTAR PROWLARR con LIDARR                       |" -ForegroundColor Green
Write-Host "  |    1. Prowlarr http://localhost:9696                 |" -ForegroundColor Green
Write-Host "  |       Settings -> Apps -> + -> Lidarr               |" -ForegroundColor Green
Write-Host "  |       URL: http://axcen-lidarr:8686                  |" -ForegroundColor Green
Write-Host "  |       API Key: (copiar de Lidarr Settings -> General)|" -ForegroundColor Green
Write-Host "  |    2. Prowlarr -> Indexers -> + -> busca y agrega   |" -ForegroundColor Green
Write-Host "  |       los que quieras (1337x, Rutracker, etc.)       |" -ForegroundColor Green
Write-Host "  |    3. Sync All -> Lidarr los hereda automaticamente  |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""

# Abrir Homarr en el navegador
Start-Process "http://localhost:7575"

Read-Host "  Pulsa ENTER para salir"
