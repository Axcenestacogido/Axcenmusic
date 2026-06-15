#Requires -Version 5.1
<#
.SYNOPSIS
    Instalador de Axcenmusic para Windows (Docker Desktop)
.DESCRIPTION
    Configura y lanza Navidrome + Webqueue en Docker Desktop.
    Al finalizar muestra todos los datos necesarios para conectar NaviBeat.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Colores ─────────────────────────────────────────────────────────────────
function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ██████████████████████████████████████████████" -ForegroundColor Cyan
    Write-Host "  █                                            █" -ForegroundColor Cyan
    Write-Host "  █        AXCENMUSIC  —  Instalador          █" -ForegroundColor Cyan
    Write-Host "  █        Navidrome + NaviBeat en Windows     █" -ForegroundColor Cyan
    Write-Host "  █                                            █" -ForegroundColor Cyan
    Write-Host "  ██████████████████████████████████████████████" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step { param([string]$Num, [string]$Text)
    Write-Host ""
    Write-Host "  [$Num] $Text" -ForegroundColor Yellow
    Write-Host "  " + ("─" * 48) -ForegroundColor DarkGray
}

function Write-OK   { param([string]$T) Write-Host "  [OK] $T" -ForegroundColor Green }
function Write-Info { param([string]$T) Write-Host "  [>>] $T" -ForegroundColor Cyan  }
function Write-Warn { param([string]$T) Write-Host "  [!!] $T" -ForegroundColor Yellow }
function Write-Fail { param([string]$T) Write-Host "  [XX] $T" -ForegroundColor Red   }

# ─── 1. Requisitos ────────────────────────────────────────────────────────────
Write-Header

Write-Step "1" "Verificando requisitos"

# Docker
try {
    $dockerVer = (docker version --format "{{.Server.Version}}" 2>$null)
    if (-not $dockerVer) { throw }
    Write-OK "Docker Desktop detectado: v$dockerVer"
} catch {
    Write-Fail "Docker Desktop no está corriendo o no está instalado."
    Write-Host ""
    Write-Host "  Descarga Docker Desktop para Windows desde:" -ForegroundColor White
    Write-Host "  https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Pasos:" -ForegroundColor White
    Write-Host "   1. Instala Docker Desktop" -ForegroundColor Gray
    Write-Host "   2. Inícialo (icono en la barra de tareas)" -ForegroundColor Gray
    Write-Host "   3. Vuelve a ejecutar este script" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Pulsa ENTER para salir"
    exit 1
}

# Docker Compose
try {
    $composeVer = (docker compose version --short 2>$null)
    Write-OK "Docker Compose detectado: v$composeVer"
} catch {
    Write-Fail "Docker Compose no disponible. Actualiza Docker Desktop."
    exit 1
}

# ─── 2. Configuración interactiva ─────────────────────────────────────────────
Write-Step "2" "Configuracion"

Write-Host ""
Write-Host "  Responde las preguntas. Pulsa ENTER para aceptar el valor por defecto." -ForegroundColor Gray
Write-Host ""

# Carpeta de música
$defaultMusic = "C:\Music"
Write-Host "  Carpeta donde esta tu musica en este PC:" -ForegroundColor White
Write-Host "  (Ejemplo: D:\Musica, C:\Users\TuNombre\Music)" -ForegroundColor DarkGray
$musicInput = Read-Host "  > Carpeta de musica [$defaultMusic]"
if ([string]::IsNullOrWhiteSpace($musicInput)) { $musicInput = $defaultMusic }
$MUSIC_DIR = $musicInput.Trim()

# Crear carpeta si no existe
if (-not (Test-Path $MUSIC_DIR)) {
    Write-Warn "La carpeta '$MUSIC_DIR' no existe. Creandola..."
    New-Item -ItemType Directory -Force -Path $MUSIC_DIR | Out-Null
    Write-OK "Carpeta creada: $MUSIC_DIR"
    Write-Warn "Pon tu musica en esa carpeta antes de usar NaviBeat."
} else {
    $count = (Get-ChildItem -Recurse -File -Include "*.mp3","*.flac","*.m4a","*.ogg","*.opus","*.wav","*.aac" $MUSIC_DIR -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-OK "Carpeta encontrada: $MUSIC_DIR ($count archivos de audio)"
}

# Puerto Navidrome
Write-Host ""
$defaultPort = "4533"
$portInput = Read-Host "  > Puerto para Navidrome [$defaultPort]"
if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = $defaultPort }
$ND_PORT = $portInput.Trim()

# ¿Instalar Webqueue?
Write-Host ""
Write-Host "  WebQueue = interfaz web para descargar musica de YouTube" -ForegroundColor DarkGray
$installWQ = Read-Host "  > Instalar WebQueue tambien? (s/N)"
$WITH_WEBQUEUE = ($installWQ.Trim().ToLower() -eq "s")

$ND_ADMIN_USER = ""
$ND_ADMIN_PASS = ""
$WEBQUEUE_PORT = "8888"

if ($WITH_WEBQUEUE) {
    Write-Host ""
    Write-Host "  Necesito las credenciales de admin de Navidrome para WebQueue." -ForegroundColor Gray
    Write-Host "  (Estas mismas credenciales las usaras en NaviBeat)" -ForegroundColor Gray
    Write-Host ""
    $ND_ADMIN_USER = Read-Host "  > Usuario admin de Navidrome [admin]"
    if ([string]::IsNullOrWhiteSpace($ND_ADMIN_USER)) { $ND_ADMIN_USER = "admin" }

    $passSecure = Read-Host "  > Contrasena admin de Navidrome" -AsSecureString
    $ND_ADMIN_PASS = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passSecure))

    $wqPortInput = Read-Host "  > Puerto para WebQueue [$WEBQUEUE_PORT]"
    if (-not [string]::IsNullOrWhiteSpace($wqPortInput)) { $WEBQUEUE_PORT = $wqPortInput.Trim() }
}

# ─── 3. Obtener IP local ──────────────────────────────────────────────────────
Write-Step "3" "Detectando red local"

$localIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet" -and $_.IPAddress -notmatch "^169" } |
    Sort-Object PrefixLength |
    Select-Object -First 1).IPAddress

if (-not $localIP) { $localIP = "localhost" }
Write-OK "IP local detectada: $localIP"

# ─── 4. Crear archivo .env ────────────────────────────────────────────────────
Write-Step "4" "Creando archivo de configuracion (.env)"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile    = Join-Path $scriptDir ".env"

# Convertir ruta Windows a formato Docker (barras normales)
$MUSIC_DIR_DOCKER = $MUSIC_DIR.Replace("\", "/")
# Para volumes en docker compose en Windows: C:/Music → /c/Music no funciona bien
# Docker Desktop acepta directamente "C:/Music" como bind mount
$envContent = @"
# Generado por install-windows.ps1
# $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

MUSIC_DIR=$MUSIC_DIR_DOCKER
ND_PORT=$ND_PORT
ND_DATA_DIR=./navidrome-data
ND_SCAN_SCHEDULE=@every 1h
ND_LOG_LEVEL=info
ND_SESSION_TIMEOUT=24h

ND_ADMIN_USER=$ND_ADMIN_USER
ND_ADMIN_PASS=$ND_ADMIN_PASS

WEBQUEUE_PORT=$WEBQUEUE_PORT
MAX_UPLOAD_MB=500

NTFY_TOPIC=
SPOTIFY_CLIENT_ID=
SPOTIFY_CLIENT_SECRET=
"@

Set-Content -Path $envFile -Value $envContent -Encoding UTF8
Write-OK ".env creado en: $envFile"

# ─── 5. Lanzar Docker Compose ─────────────────────────────────────────────────
Write-Step "5" "Lanzando servicios Docker"

$composeFile = Join-Path $scriptDir "docker-compose.windows.yml"

if (-not (Test-Path $composeFile)) {
    Write-Fail "No se encontro docker-compose.windows.yml en: $scriptDir"
    Write-Warn "Asegurate de ejecutar este script desde la carpeta raiz del proyecto."
    exit 1
}

try {
    if ($WITH_WEBQUEUE) {
        Write-Info "Construyendo y levantando Navidrome + WebQueue..."
        & docker compose -f $composeFile --env-file $envFile --profile extras up -d --build 2>&1
    } else {
        Write-Info "Levantando Navidrome..."
        & docker compose -f $composeFile --env-file $envFile up -d 2>&1
    }

    if ($LASTEXITCODE -ne 0) { throw "docker compose fallo con codigo $LASTEXITCODE" }
    Write-OK "Contenedores iniciados"
} catch {
    Write-Fail "Error al lanzar Docker Compose: $_"
    Write-Host ""
    Write-Host "  Revisa que Docker Desktop este corriendo y vuelve a intentarlo." -ForegroundColor Gray
    exit 1
}

# ─── 6. Esperar a que Navidrome este listo ────────────────────────────────────
Write-Step "6" "Esperando que Navidrome arranque"

Write-Info "Esperando hasta 90 segundos..."
$maxWait  = 90
$interval = 5
$elapsed  = 0
$ready    = $false

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$ND_PORT/ping" -TimeoutSec 3 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            $ready = $true
            break
        }
    } catch { }
    Write-Host "  Esperando... ($elapsed s)" -ForegroundColor DarkGray
}

if ($ready) {
    Write-OK "Navidrome esta listo y respondiendo!"
} else {
    Write-Warn "Navidrome tarda mas de lo normal. Puede que aun este arrancando."
    Write-Info "Abre http://localhost:$ND_PORT en el navegador en unos segundos."
}

# ─── 7. Crear usuario admin en Navidrome (primera vez) ───────────────────────
if ($WITH_WEBQUEUE -and $ready) {
    Write-Step "7" "Configurando usuario admin en Navidrome"
    Write-Info "Abre http://localhost:$ND_PORT en el navegador."
    Write-Info "La primera vez que entres, Navidrome te pedira crear el admin."
    Write-Info "Usa exactamente estos datos:"
    Write-Host "    Usuario:    $ND_ADMIN_USER" -ForegroundColor White
    Write-Host "    Contrasena: $ND_ADMIN_PASS" -ForegroundColor White
    Write-Host ""
    Read-Host "  Pulsa ENTER cuando hayas creado el usuario en el navegador"
}

# ─── 8. Resumen final con datos para NaviBeat ─────────────────────────────────
Write-Host ""
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║         AXCENMUSIC INSTALADO CORRECTAMENTE          ║" -ForegroundColor Green
Write-Host "  ╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  DATOS PARA NAVIBEAT (iOS)                          ║" -ForegroundColor Green
Write-Host "  ║  ─────────────────────────────────────────────────  ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  Abre NaviBeat > Ajustes > Agregar servidor         ║" -ForegroundColor Green
Write-Host "  ║  Selecciona tipo: Subsonic / OpenSubsonic           ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green

$serverURL = "http://${localIP}:${ND_PORT}"
Write-Host "  ║  URL del servidor:                                   ║" -ForegroundColor Green
Write-Host "  ║    $serverURL" -ForegroundColor Cyan
if ($localIP -ne "localhost") {
    Write-Host "  ║    http://localhost:$ND_PORT  (solo en este PC)      ║" -ForegroundColor DarkGray
}
Write-Host "  ║                                                      ║" -ForegroundColor Green

if ($WITH_WEBQUEUE -and $ND_ADMIN_USER) {
    Write-Host "  ║  Usuario:  $ND_ADMIN_USER" -ForegroundColor Green
    Write-Host "  ║  Contrasena: (la que configuraste)                  ║" -ForegroundColor Green
} else {
    Write-Host "  ║  Usuario:  el que crees en la primera apertura      ║" -ForegroundColor Green
    Write-Host "  ║  URL admin: http://localhost:$ND_PORT                  ║" -ForegroundColor Green
}

Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  INTERFACES WEB                                      ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  Navidrome (admin):  http://localhost:$ND_PORT           ║" -ForegroundColor Green

if ($WITH_WEBQUEUE) {
    Write-Host "  ║  WebQueue (descargas): http://localhost:$WEBQUEUE_PORT        ║" -ForegroundColor Green
}

Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  CARPETA DE MUSICA                                   ║" -ForegroundColor Green
Write-Host "  ║    $MUSIC_DIR" -ForegroundColor Cyan
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  COMANDOS UTILES                                     ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║  Ver logs:   docker logs axcen-navidrome -f          ║" -ForegroundColor DarkGray
Write-Host "  ║  Parar:      docker compose -f docker-compose.windows.yml down" -ForegroundColor DarkGray
Write-Host "  ║  Reiniciar:  docker compose -f docker-compose.windows.yml up -d" -ForegroundColor DarkGray
Write-Host "  ║  Actualizar: docker compose -f docker-compose.windows.yml pull" -ForegroundColor DarkGray
Write-Host "  ║              docker compose -f docker-compose.windows.yml up -d" -ForegroundColor DarkGray
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# ─── Guardar resumen en archivo ───────────────────────────────────────────────
$summaryFile = Join-Path $scriptDir "NAVIBEAT-DATOS.txt"
$summary = @"
========================================================
  AXCENMUSIC — Datos de conexion para NaviBeat
  Generado: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
========================================================

DATOS PARA NAVIBEAT (iOS)
─────────────────────────
Abre NaviBeat → Ajustes → Agregar servidor
Selecciona tipo: Subsonic / OpenSubsonic

  URL del servidor : http://${localIP}:${ND_PORT}
  URL (local PC)   : http://localhost:${ND_PORT}
$(if ($WITH_WEBQUEUE -and $ND_ADMIN_USER) { "  Usuario          : $ND_ADMIN_USER`n  Contrasena       : (la que configuraste)" } else { "  Usuario          : el que crees en la primera apertura`n                     http://localhost:${ND_PORT}" })

INTERFACES WEB
──────────────
  Navidrome (admin)    : http://localhost:${ND_PORT}
$(if ($WITH_WEBQUEUE) { "  WebQueue (descargas) : http://localhost:${WEBQUEUE_PORT}" })

CARPETA DE MUSICA
─────────────────
  $MUSIC_DIR

COMANDOS UTILES
───────────────
  Ver logs de Navidrome:
    docker logs axcen-navidrome -f

  Parar todos los servicios:
    docker compose -f docker-compose.windows.yml down

  Volver a iniciar:
    docker compose -f docker-compose.windows.yml up -d

  Actualizar Navidrome a la ultima version:
    docker compose -f docker-compose.windows.yml pull
    docker compose -f docker-compose.windows.yml up -d

  Forzar rescan de biblioteca:
    Navidrome admin → Biblioteca → Escanear ahora

PASOS PARA NAVIBEAT (primera vez)
──────────────────────────────────
  1. Descarga NaviBeat en el App Store (iPhone/iPad)
  2. Abre la app → Pulsa el icono de ajustes (engranaje)
  3. Selecciona "Add Server" / "Agregar servidor"
  4. Elige tipo: "Subsonic" o "OpenSubsonic"
  5. Rellena los campos:
       - Server URL: http://${localIP}:${ND_PORT}
       - Username  : tu usuario de Navidrome
       - Password  : tu contrasena de Navidrome
  6. Pulsa "Test Connection" — debe decir OK
  7. Guarda y disfruta tu musica!

NOTA IMPORTANTE
───────────────
  - NaviBeat solo puede conectar si esta en la misma red WiFi que este PC
  - Para acceso desde fuera de casa, instala Tailscale en el PC y en el iPhone
  - La IP local puede cambiar; asignale una IP fija al PC en el router
    (busca "DHCP reservation" en la configuracion de tu router)

========================================================
"@

Set-Content -Path $summaryFile -Value $summary -Encoding UTF8
Write-Host "  Los datos anteriores se guardaron en:" -ForegroundColor DarkGray
Write-Host "  $summaryFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Abriendo el archivo de resumen..." -ForegroundColor DarkGray
Start-Process notepad.exe $summaryFile

Write-Host ""
Read-Host "  Pulsa ENTER para salir"
