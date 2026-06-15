#Requires -Version 5.1
<#
.SYNOPSIS
    Configura Tailscale Funnel para exponer Navidrome publicamente via HTTPS.
.DESCRIPTION
    Instala Tailscale (si no esta), autentica, activa Funnel en el puerto
    de Navidrome y muestra la URL publica para usar en NaviBeat desde
    cualquier red (datos moviles, WiFi ajena, etc.).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-OK   { param([string]$T) Write-Host "  [OK] $T" -ForegroundColor Green  }
function Write-Info { param([string]$T) Write-Host "  [>>] $T" -ForegroundColor Cyan   }
function Write-Warn { param([string]$T) Write-Host "  [!!] $T" -ForegroundColor Yellow }
function Write-Fail { param([string]$T) Write-Host "  [XX] $T" -ForegroundColor Red    }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile   = Join-Path $scriptDir ".env"

# --- Leer puerto de Navidrome desde .env ------------------------------------
$ND_PORT = "4533"
if (Test-Path $envFile) {
    $envLine = (Get-Content $envFile | Where-Object { $_ -match "^ND_PORT=" }) | Select-Object -First 1
    if ($envLine) { $ND_PORT = $envLine -replace "^ND_PORT=", "" }
}

Write-Host ""
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host "  #   AXCENMUSIC -- Tailscale Funnel Setup   #" -ForegroundColor Cyan
Write-Host "  ##############################################" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Tailscale Funnel crea una URL publica HTTPS para" -ForegroundColor Gray
Write-Host "  Navidrome accesible desde cualquier red o pais." -ForegroundColor Gray
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

# --- 4. Activar Tailscale Serve + Funnel ------------------------------------
Write-Host ""
Write-Host "  [4] Activando Tailscale Funnel en puerto $ND_PORT..." -ForegroundColor Yellow
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

Write-Info "Configurando Tailscale Serve (proxy HTTPS -> localhost:$ND_PORT)..."
& $tailscaleExe serve --bg https / "http://localhost:$ND_PORT"
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Serve ya configurado o error menor. Continuando..."
}

Write-Info "Activando Funnel (exposicion publica)..."
& $tailscaleExe funnel --bg https on
if ($LASTEXITCODE -ne 0) {
    Write-Fail "No se pudo activar Funnel."
    Write-Host ""
    Write-Host "  Requisitos para Tailscale Funnel:" -ForegroundColor White
    Write-Host "   - La cuenta debe tener Funnel habilitado" -ForegroundColor Gray
    Write-Host "   - Activa Funnel en: https://login.tailscale.com/admin/dns" -ForegroundColor Gray
    Write-Host "     (seccion 'HTTPS Certificates' + 'Funnel')" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Pulsa ENTER para salir"
    exit 1
}

$publicURL = "https://$tsDNS"
Write-OK "Funnel activo: $publicURL"

# --- 5. Resumen y actualizar NAVIBEAT-DATOS.txt -----------------------------
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |        TAILSCALE FUNNEL CONFIGURADO                 |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  URL PUBLICA (usa esta en NaviBeat):                |" -ForegroundColor Green
$pad = " " * [Math]::Max(0, 50 - $publicURL.Length)
Write-Host "  |    $publicURL$pad|" -ForegroundColor Cyan
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  Accesible desde cualquier red / pais               |" -ForegroundColor Green
Write-Host "  |  Sin VPN, sin abrir puertos en el router            |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  En NaviBeat:                                        |" -ForegroundColor Green
Write-Host "  |    Server URL : $publicURL" -ForegroundColor Cyan
Write-Host "  |    Tipo       : Subsonic / OpenSubsonic              |" -ForegroundColor Green
Write-Host "  |    Usuario    : tu usuario de Navidrome              |" -ForegroundColor Green
Write-Host "  |    Contrasena : tu contrasena de Navidrome           |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""
Write-Host "  NOTA: si apagas o reinicias el PC, ejecuta:" -ForegroundColor DarkGray
Write-Host "    tailscale funnel --bg https on" -ForegroundColor DarkGray
Write-Host "  para reactivar el Funnel." -ForegroundColor DarkGray
Write-Host ""

# Actualizar NAVIBEAT-DATOS.txt
$summaryFile = Join-Path $scriptDir "NAVIBEAT-DATOS.txt"
$funnelBlock = @"

URL PUBLICA (Tailscale Funnel) -- desde cualquier red
------------------------------------------------------
  $publicURL

  En NaviBeat:
    Server URL : $publicURL
    Tipo       : Subsonic / OpenSubsonic
    Usuario    : tu usuario de Navidrome
    Contrasena : tu contrasena de Navidrome

  Para reactivar Funnel tras reiniciar el PC:
    tailscale funnel --bg https on

"@

if (Test-Path $summaryFile) {
    $existing = Get-Content $summaryFile -Raw
    if ($existing -notmatch "Tailscale Funnel") {
        Add-Content -Path $summaryFile -Value $funnelBlock -Encoding UTF8
        Write-OK "NAVIBEAT-DATOS.txt actualizado con la URL publica."
    } else {
        # Reemplazar URL anterior si ya existia
        $existing = $existing -replace "https://[^\s]+\.ts\.net", $publicURL
        Set-Content -Path $summaryFile -Value $existing -Encoding UTF8
        Write-OK "NAVIBEAT-DATOS.txt actualizado."
    }
}

Start-Process notepad.exe $summaryFile
Write-Host ""
Read-Host "  Pulsa ENTER para salir"
