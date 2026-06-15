#Requires -Version 5.1
<#
.SYNOPSIS
    Configura Tailscale para exponer todos los servicios de Axcenmusic.
.DESCRIPTION
    - Navidrome : Funnel publico en puerto 443 (para NaviBeat sin VPN)
    - WebQueue  : Funnel publico en puerto 8443
    - Resto     : Tailscale Serve (acceso Tailnet, requiere Tailscale en cliente)
    Nota: Tailscale Funnel solo soporta los puertos 443, 8443 y 10000.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-OK   { param([string]$T) Write-Host "  [OK] $T" -ForegroundColor Green  }
function Write-Info { param([string]$T) Write-Host "  [>>] $T" -ForegroundColor Cyan   }
function Write-Warn { param([string]$T) Write-Host "  [!!] $T" -ForegroundColor Yellow }
function Write-Fail { param([string]$T) Write-Host "  [XX] $T" -ForegroundColor Red    }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile   = Join-Path $scriptDir ".env"

# --- Leer puertos desde .env ------------------------------------------------
$ND_PORT       = "4533"
$WEBQUEUE_PORT = "8888"
$LIDARR_PORT   = "8686"
$PROWLARR_PORT = "9696"
$SLSKD_PORT    = "5030"
$TAGS_PORT     = "6677"
$HOMARR_PORT   = "7575"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^ND_PORT=(.+)")          { $ND_PORT = $Matches[1] }
        if ($_ -match "^WEBQUEUE_PORT=(.+)")    { $WEBQUEUE_PORT = $Matches[1] }
        if ($_ -match "^LIDARR_PORT=(.+)")      { $LIDARR_PORT = $Matches[1] }
        if ($_ -match "^PROWLARR_PORT=(.+)")    { $PROWLARR_PORT = $Matches[1] }
        if ($_ -match "^SLSKD_PORT=(.+)")       { $SLSKD_PORT = $Matches[1] }
        if ($_ -match "^MUSIC_TAG_PORT=(.+)")   { $TAGS_PORT = $Matches[1] }
        if ($_ -match "^HOMARR_PORT=(.+)")      { $HOMARR_PORT = $Matches[1] }
    }
}

Write-Host ""
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host "  #   AXCENMUSIC -- Tailscale Funnel Setup   #" -ForegroundColor Cyan
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Expone todos los servicios de Axcenmusic via Tailscale." -ForegroundColor Gray
Write-Host "  Navidrome y WebQueue: publicos sin VPN." -ForegroundColor Gray
Write-Host "  Resto: accesibles con Tailscale instalado en tu movil/PC." -ForegroundColor Gray
Write-Host ""

# --- 1. Verificar / instalar Tailscale --------------------------------------
Write-Host "  [1] Verificando Tailscale..." -ForegroundColor Yellow
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

$tailscaleExe = $null
$tsPaths = @(
    (Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"),
    (Join-Path ([System.Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) "Tailscale\tailscale.exe"),
    "tailscale.exe"
)
foreach ($p in $tsPaths) {
    try {
        if (Get-Command $p -ErrorAction SilentlyContinue) { $tailscaleExe = $p; break }
    } catch { }
}
if (-not $tailscaleExe) {
    try { Get-Command tailscale -ErrorAction Stop | Out-Null; $tailscaleExe = "tailscale" } catch { }
}

if (-not $tailscaleExe) {
    Write-Warn "Tailscale no esta instalado. Instalando via winget..."
    & winget install Tailscale.Tailscale --source winget --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "No se pudo instalar Tailscale."
        Write-Host "  Descargalo manualmente desde: https://tailscale.com/download/windows" -ForegroundColor White
        Read-Host "  Pulsa ENTER para salir"
        exit 1
    }
    # Refrescar PATH para encontrar el ejecutable recien instalado
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    $tailscaleExe = "tailscale"
    Write-OK "Tailscale instalado."
} else {
    $tsVer = (& $tailscaleExe version 2>$null | Select-Object -First 1)
    Write-OK "Tailscale encontrado: $tsVer"
}

# --- 2. Comprobar si ya esta autenticado ------------------------------------
Write-Host ""
Write-Host "  [2] Comprobando autenticacion en Tailscale..." -ForegroundColor Yellow
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

$tsStatus = (& $tailscaleExe status 2>$null)
$isLoggedIn = ($tsStatus -notmatch "Logged out" -and $tsStatus -notmatch "NeedsLogin" -and $tsStatus -ne "")

if (-not $isLoggedIn) {
    Write-Warn "No estas autenticado en Tailscale."
    Write-Host ""
    Write-Host "  Se abrira el navegador para iniciar sesion en Tailscale." -ForegroundColor White
    Write-Host "  Si no tienes cuenta, puedes crear una gratis en tailscale.com" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Pulsa ENTER para abrir el navegador y autenticarte"
    & $tailscaleExe login
    Write-Host ""
    Write-Host "  Esperando autenticacion..." -ForegroundColor Gray
    $waited = 0
    while ($waited -lt 120) {
        Start-Sleep -Seconds 3
        $waited += 3
        $tsStatus = (& $tailscaleExe status 2>$null)
        if ($tsStatus -notmatch "Logged out" -and $tsStatus -notmatch "NeedsLogin" -and $tsStatus -ne "") {
            break
        }
        Write-Host "  Esperando... ($waited s)" -ForegroundColor DarkGray
    }
    $tsStatus = (& $tailscaleExe status 2>$null)
    if ($tsStatus -match "Logged out" -or $tsStatus -match "NeedsLogin") {
        Write-Fail "No se completo la autenticacion en 2 minutos."
        Write-Host "  Ejecuta este script de nuevo cuando hayas iniciado sesion en Tailscale." -ForegroundColor Gray
        exit 1
    }
    Write-OK "Autenticado en Tailscale."
} else {
    Write-OK "Ya autenticado en Tailscale."
}

# --- 3. Obtener nombre del host en Tailscale --------------------------------
Write-Host ""
Write-Host "  [3] Obteniendo datos de la red Tailscale..." -ForegroundColor Yellow
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

$tsDNS = $null
try {
    $tsJson = (& $tailscaleExe status --json 2>$null) | ConvertFrom-Json
    $tsDNS  = $tsJson.Self.DNSName -replace "\.$", ""   # quitar punto final
} catch { }

if (-not $tsDNS) {
    Write-Warn "No se pudo obtener el nombre DNS de Tailscale automaticamente."
    Write-Host "  Busca tu hostname en https://login.tailscale.com/admin/machines" -ForegroundColor Gray
    $tsDNS = Read-Host "  > Introduce tu hostname Tailscale (ej: mi-pc.tail1234.ts.net)"
}
Write-OK "Hostname Tailscale: $tsDNS"

# --- 4. Tailscale Serve para servicios internos (Tailnet) -------------------
Write-Host ""
Write-Host "  [4] Configurando Tailscale Serve (acceso via Tailscale VPN)..." -ForegroundColor Yellow
Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Nota: para usar estas URLs instala Tailscale en tu movil/PC." -ForegroundColor DarkGray
Write-Host ""

Write-Info "Serve Lidarr    -> https://${tsDNS}:${LIDARR_PORT}"
& $tailscaleExe serve --https=$LIDARR_PORT "http://localhost:$LIDARR_PORT"
Write-Info "Serve Prowlarr  -> https://${tsDNS}:${PROWLARR_PORT}"
& $tailscaleExe serve --https=$PROWLARR_PORT "http://localhost:$PROWLARR_PORT"
Write-Info "Serve Soulseek  -> https://${tsDNS}:${SLSKD_PORT}"
& $tailscaleExe serve --https=$SLSKD_PORT "http://localhost:$SLSKD_PORT"
Write-Info "Serve Tags      -> https://${tsDNS}:${TAGS_PORT}"
& $tailscaleExe serve --https=$TAGS_PORT "http://localhost:$TAGS_PORT"
Write-Info "Serve Homepage  -> https://${tsDNS}:${HOMARR_PORT}"
& $tailscaleExe serve --https=$HOMARR_PORT "http://localhost:$HOMARR_PORT"
Write-OK "Serve configurado para todos los servicios."

# --- 5. Tailscale Funnel publico (puertos 443 y 8443) -----------------------
Write-Host ""
Write-Host "  [5] Activando Funnel publico (Navidrome + WebQueue)..." -ForegroundColor Yellow
Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Tailscale Funnel solo soporta puertos 443, 8443 y 10000." -ForegroundColor DarkGray
Write-Host ""

Write-Info "Funnel Navidrome -> https://$tsDNS (puerto 443)"
& $tailscaleExe funnel --bg --https=443 "http://localhost:$ND_PORT"
if ($LASTEXITCODE -ne 0) {
    Write-Fail "No se pudo activar Funnel para Navidrome."
    Write-Host ""
    Write-Host "  Requisitos para Tailscale Funnel:" -ForegroundColor White
    Write-Host "   - La cuenta debe tener Funnel habilitado" -ForegroundColor Gray
    Write-Host "   - Activa Funnel en: https://login.tailscale.com/admin/dns" -ForegroundColor Gray
    Write-Host "     (seccion 'HTTPS Certificates' + 'Funnel')" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Pulsa ENTER para salir"
    exit 1
}
Write-OK "Funnel Navidrome activo: https://$tsDNS"

Write-Info "Funnel WebQueue  -> https://${tsDNS}:8443"
& $tailscaleExe funnel --bg --https=8443 "http://localhost:$WEBQUEUE_PORT"
if ($LASTEXITCODE -ne 0) {
    Write-Warn "No se pudo activar Funnel para WebQueue. Continuando..."
} else {
    Write-OK "Funnel WebQueue activo: https://${tsDNS}:8443"
}

$publicURL = "https://$tsDNS"

# --- 6. Resumen y actualizar NAVIBEAT-DATOS.txt -----------------------------
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |        TAILSCALE CONFIGURADO                        |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  PUBLICO (sin necesidad de Tailscale en cliente):   |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  Navidrome (NaviBeat):                              |" -ForegroundColor Green
Write-Host "  |    $publicURL" -ForegroundColor Cyan
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  WebQueue (descarga musica):                        |" -ForegroundColor Green
Write-Host "  |    https://${tsDNS}:8443" -ForegroundColor Cyan
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  CON TAILSCALE en tu movil/PC (instala la app):    |" -ForegroundColor Green
Write-Host "  |    Lidarr   -> https://${tsDNS}:$LIDARR_PORT" -ForegroundColor DarkGray
Write-Host "  |    Prowlarr -> https://${tsDNS}:$PROWLARR_PORT" -ForegroundColor DarkGray
Write-Host "  |    Soulseek -> https://${tsDNS}:$SLSKD_PORT" -ForegroundColor DarkGray
Write-Host "  |    Tags     -> https://${tsDNS}:$TAGS_PORT" -ForegroundColor DarkGray
Write-Host "  |    Homepage -> https://${tsDNS}:$HOMARR_PORT" -ForegroundColor DarkGray
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  En NaviBeat:                                        |" -ForegroundColor Green
Write-Host "  |    Server URL : $publicURL" -ForegroundColor Cyan
Write-Host "  |    Tipo       : Subsonic / OpenSubsonic              |" -ForegroundColor Green
Write-Host "  |    Usuario    : tu usuario de Navidrome              |" -ForegroundColor Green
Write-Host "  |    Contrasena : tu contrasena de Navidrome           |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""
Write-Host "  Si reinicias el PC: tailscale serve reset + ejecuta este script." -ForegroundColor DarkGray
Write-Host ""

# Actualizar NAVIBEAT-DATOS.txt
$summaryFile = Join-Path $scriptDir "NAVIBEAT-DATOS.txt"
$funnelBlock = @"

=== ACCESO EXTERNO (Tailscale) ===

PUBLICO -- sin Tailscale en el cliente:
  Navidrome : $publicURL
  WebQueue  : https://${tsDNS}:8443

CON TAILSCALE instalado en tu movil/PC:
  Lidarr    : https://${tsDNS}:$LIDARR_PORT
  Prowlarr  : https://${tsDNS}:$PROWLARR_PORT
  Soulseek  : https://${tsDNS}:$SLSKD_PORT
  Tags      : https://${tsDNS}:$TAGS_PORT
  Homepage  : https://${tsDNS}:$HOMARR_PORT

En NaviBeat:
  Server URL : $publicURL
  Tipo       : Subsonic / OpenSubsonic
  Usuario    : tu usuario de Navidrome
  Contrasena : tu contrasena de Navidrome

"@

$summaryFile = Join-Path $scriptDir "NAVIBEAT-DATOS.txt"
if (Test-Path $summaryFile) {
    $existing = Get-Content $summaryFile -Raw
    if ($existing -notmatch "ACCESO EXTERNO") {
        Add-Content -Path $summaryFile -Value $funnelBlock -Encoding UTF8
        Write-OK "NAVIBEAT-DATOS.txt actualizado con las URLs externas."
    } else {
        $existing = $existing -replace "https://[^\s]+\.ts\.net", $publicURL
        Set-Content -Path $summaryFile -Value $existing -Encoding UTF8
        Write-OK "NAVIBEAT-DATOS.txt actualizado."
    }
}

if (Test-Path $summaryFile) { Start-Process notepad.exe $summaryFile }
Write-Host ""
Read-Host "  Pulsa ENTER para salir"
