#Requires -Version 5.1
<#
.SYNOPSIS
    Instalador de Axcenmusic para Windows (Docker Desktop)
.DESCRIPTION
    Configura y lanza Navidrome + Webqueue en Docker Desktop.
    Incluye paso guiado de etiquetado con Mp3tag.
    Al finalizar muestra todos los datos para conectar NaviBeat.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ##############################################" -ForegroundColor Cyan
    Write-Host "  #                                          #" -ForegroundColor Cyan
    Write-Host "  #       AXCENMUSIC  --  Instalador        #" -ForegroundColor Cyan
    Write-Host "  #       Navidrome + NaviBeat en Windows    #" -ForegroundColor Cyan
    Write-Host "  #                                          #" -ForegroundColor Cyan
    Write-Host "  ##############################################" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step { param([string]$Num, [string]$Text)
    Write-Host ""
    Write-Host "  [$Num] $Text" -ForegroundColor Yellow
    Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
}

function Write-OK   { param([string]$T) Write-Host "  [OK] $T" -ForegroundColor Green  }
function Write-Info { param([string]$T) Write-Host "  [>>] $T" -ForegroundColor Cyan   }
function Write-Warn { param([string]$T) Write-Host "  [!!] $T" -ForegroundColor Yellow }
function Write-Fail { param([string]$T) Write-Host "  [XX] $T" -ForegroundColor Red    }
function Write-Tip  { param([string]$T) Write-Host "      $T"  -ForegroundColor DarkGray }

# --- 1. Requisitos ------------------------------------------------------------
Write-Header

Write-Step "1" "Verificando requisitos"

try {
    $dockerVer = (docker version --format "{{.Server.Version}}" 2>$null)
    if (-not $dockerVer) { throw }
    Write-OK "Docker Desktop detectado: v$dockerVer"
} catch {
    Write-Fail "Docker Desktop no esta corriendo o no esta instalado."
    Write-Host ""
    Write-Host "  Descarga Docker Desktop para Windows desde:" -ForegroundColor White
    Write-Host "  https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Pasos:" -ForegroundColor White
    Write-Host "   1. Instala Docker Desktop" -ForegroundColor Gray
    Write-Host "   2. Inicialo (icono en la barra de tareas)" -ForegroundColor Gray
    Write-Host "   3. Vuelve a ejecutar este script" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Pulsa ENTER para salir"
    exit 1
}

try {
    $composeVer = (docker compose version --short 2>$null)
    Write-OK "Docker Compose detectado: v$composeVer"
} catch {
    Write-Fail "Docker Compose no disponible. Actualiza Docker Desktop."
    exit 1
}

# --- 2. Configuracion ---------------------------------------------------------
Write-Step "2" "Configuracion"

Write-Host ""
Write-Host "  Pulsa ENTER para aceptar el valor por defecto." -ForegroundColor Gray
Write-Host ""

$defaultMusic = "C:\Music"
Write-Host "  Carpeta donde esta tu musica en este PC:" -ForegroundColor White
Write-Host "  (Ejemplo: D:\Musica, C:\Users\TuNombre\Music)" -ForegroundColor DarkGray
$musicInput = Read-Host "  > Carpeta de musica [$defaultMusic]"
if ([string]::IsNullOrWhiteSpace($musicInput)) { $musicInput = $defaultMusic }
$MUSIC_DIR = $musicInput.Trim()

if (-not (Test-Path $MUSIC_DIR)) {
    Write-Warn "La carpeta '$MUSIC_DIR' no existe. Creandola..."
    New-Item -ItemType Directory -Force -Path $MUSIC_DIR | Out-Null
    Write-OK "Carpeta creada: $MUSIC_DIR"
    Write-Warn "Pon tu musica en esa carpeta y luego etiquetala con Mp3tag (paso 3)."
} else {
    $count = (Get-ChildItem -Recurse -File -Include "*.mp3","*.flac","*.m4a","*.ogg","*.opus","*.wav","*.aac" $MUSIC_DIR -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-OK "Carpeta encontrada: $MUSIC_DIR ($count archivos de audio)"
}

Write-Host ""
$defaultPort = "4533"
$portInput = Read-Host "  > Puerto para Navidrome [$defaultPort]"
if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = $defaultPort }
$ND_PORT = $portInput.Trim()

Write-Host ""
Write-Host "  WebQueue = interfaz web para descargar musica de YouTube" -ForegroundColor DarkGray
$installWQ = Read-Host "  > Instalar WebQueue tambien? (s/N)"
$WITH_WEBQUEUE = ($installWQ.Trim().ToLower() -eq "s")

$ND_ADMIN_USER = ""
$ND_ADMIN_PASS = ""
$WEBQUEUE_PORT = "8888"

if ($WITH_WEBQUEUE) {
    Write-Host ""
    Write-Host "  Credenciales de admin (las mismas que usaras en NaviBeat):" -ForegroundColor Gray
    Write-Host ""
    $ND_ADMIN_USER = Read-Host "  > Usuario admin de Navidrome [admin]"
    if ([string]::IsNullOrWhiteSpace($ND_ADMIN_USER)) { $ND_ADMIN_USER = "admin" }

    $passSecure = Read-Host "  > Contrasena admin de Navidrome" -AsSecureString
    $ND_ADMIN_PASS = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passSecure))

    $wqPortInput = Read-Host "  > Puerto para WebQueue [$WEBQUEUE_PORT]"
    if (-not [string]::IsNullOrWhiteSpace($wqPortInput)) { $WEBQUEUE_PORT = $wqPortInput.Trim() }
}

# --- 3. Etiquetar musica con Mp3tag ------------------------------------------
Write-Step "3" "Etiquetar musica con Mp3tag  (recomendado)"

Write-Host ""
Write-Host "  Navidrome organiza tu biblioteca por etiquetas (tags) incrustadas" -ForegroundColor White
Write-Host "  en cada archivo. Sin etiquetas, todo aparece como artista" -ForegroundColor White
Write-Host "  desconocido en NaviBeat." -ForegroundColor White
Write-Host ""
Write-Host "  Mp3tag es gratuito y edita en bloque como una tabla Excel." -ForegroundColor Gray
Write-Host "  En 20 minutos tienes toda tu coleccion bien organizada." -ForegroundColor Gray
Write-Host ""
Write-Host "  Campos clave para NaviBeat:" -ForegroundColor Cyan
Write-Tip "TITLE   -> nombre de la cancion (ej. Bohemian Rhapsody)"
Write-Tip "ARTIST  -> interprete           (ej. Queen)"
Write-Tip "ALBUM   -> nombre del album     (ej. A Night at the Opera)"
Write-Tip "YEAR    -> anio de lanzamiento  (ej. 1975)"
Write-Tip "TRACK   -> numero de pista      (ej. 11)"
Write-Tip "COVER   -> caratula del album   (boton derecho -> Extended Tags)"
Write-Host ""

$skipTag = Read-Host "  > Saltar este paso? Ya tengo mis archivos bien etiquetados (s/N)"
if ($skipTag.Trim().ToLower() -ne "s") {

    # Buscar Mp3tag instalado
    $pf86     = [System.Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $mp3tagPaths = @(
        (Join-Path $env:ProgramFiles "Mp3tag\Mp3tag.exe"),
        (Join-Path $pf86 "Mp3tag\Mp3tag.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Mp3tag\Mp3tag.exe")
    )
    $mp3tagExe = $mp3tagPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if (-not $mp3tagExe) {
        Write-Warn "Mp3tag no esta instalado."
        Write-Host ""
        $installMp3 = Read-Host "  > Instalar Mp3tag automaticamente con winget? (S/n)"
        if ($installMp3.Trim().ToLower() -ne "n") {
            Write-Info "Instalando Mp3tag via winget..."
            try {
                & winget install --id Mp3tag.Mp3tag --source winget --silent --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -ne 0) { throw "winget fallo" }
                $mp3tagExe = $mp3tagPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
                if ($mp3tagExe) {
                    Write-OK "Mp3tag instalado en: $mp3tagExe"
                } else {
                    Write-Warn "Instalado pero no encontrado en ruta estandar."
                    Write-Warn "Abrelo manualmente desde el menu Inicio."
                    $mp3tagExe = $null
                }
            } catch {
                Write-Warn "No se pudo instalar via winget."
                Write-Host ""
                Write-Host "  Descargalo manualmente desde:" -ForegroundColor White
                Write-Host "  https://www.mp3tag.de/en/download.html" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Despues abrelo, arrastra la carpeta '$MUSIC_DIR'" -ForegroundColor Gray
                Write-Host "  y edita las columnas: Title, Artist, Album, Year, Track." -ForegroundColor Gray
                $mp3tagExe = $null
            }
        } else {
            Write-Info "De acuerdo. Puedes etiquetar mas tarde y forzar un rescan en Navidrome."
            $mp3tagExe = $null
        }
    } else {
        Write-OK "Mp3tag encontrado: $mp3tagExe"
    }

    if ($mp3tagExe) {
        Write-Host ""
        Write-Host "  +-----------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "  |  GUIA RAPIDA DE MP3TAG                              |" -ForegroundColor Cyan
        Write-Host "  |                                                     |" -ForegroundColor Cyan
        Write-Host "  |  1. Mp3tag se abrira con tu carpeta cargada         |" -ForegroundColor Cyan
        Write-Host "  |  2. Ctrl+A para seleccionar todos los archivos      |" -ForegroundColor Cyan
        Write-Host "  |  3. Edita las columnas directamente (como Excel)    |" -ForegroundColor Cyan
        Write-Host "  |  4. Caratula: boton derecho -> Extended Tags        |" -ForegroundColor Cyan
        Write-Host "  |  5. Ctrl+S para guardar todos los cambios           |" -ForegroundColor Cyan
        Write-Host "  |  6. Cierra Mp3tag cuando termines                   |" -ForegroundColor Cyan
        Write-Host "  +-----------------------------------------------------+" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Abriendo Mp3tag con tu carpeta de musica..." -ForegroundColor Gray

        Start-Process -FilePath $mp3tagExe -ArgumentList "/fp:`"$MUSIC_DIR`""

        Write-Host ""
        Write-Host "  Cuando termines de etiquetar y hayas cerrado Mp3tag," -ForegroundColor White
        Write-Host "  vuelve aqui y pulsa ENTER para continuar." -ForegroundColor White
        Write-Host ""
        Read-Host "  Pulsa ENTER cuando hayas terminado de etiquetar"
        Write-OK "Listo. Continuando con la instalacion..."
    }

} else {
    Write-OK "Paso de etiquetado omitido."
}

# --- 4. Detectar IP local -----------------------------------------------------
Write-Step "4" "Detectando red local"

$localIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet" -and $_.IPAddress -notmatch "^169" } |
    Sort-Object PrefixLength |
    Select-Object -First 1).IPAddress

if (-not $localIP) { $localIP = "localhost" }
Write-OK "IP local detectada: $localIP"
Write-Tip "(Esta es la URL que usara NaviBeat para conectar)"

# --- 5. Crear archivo .env ----------------------------------------------------
Write-Step "5" "Creando archivo de configuracion (.env)"

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile     = Join-Path $scriptDir ".env"
$MUSIC_DIR_DOCKER = $MUSIC_DIR.Replace("\", "/")

$envContent = @"
# Generado por install-windows.ps1 -- $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

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

# --- 6. Lanzar Docker Compose -------------------------------------------------
Write-Step "6" "Lanzando servicios Docker"

$composeFile = Join-Path $scriptDir "docker-compose.windows.yml"

if (-not (Test-Path $composeFile)) {
    Write-Fail "No se encontro docker-compose.windows.yml en: $scriptDir"
    Write-Warn "Asegurate de ejecutar este script desde la carpeta raiz del proyecto."
    exit 1
}

try {
    if ($WITH_WEBQUEUE) {
        Write-Info "Construyendo y levantando Navidrome + WebQueue..."
        Write-Info "(La primera vez puede tardar 5-10 min descargando imagenes. Espera...)"
        & docker compose -f $composeFile --env-file $envFile --profile extras up -d --build
    } else {
        Write-Info "Levantando Navidrome..."
        Write-Info "(La primera vez puede tardar 2-5 min descargando la imagen. Espera...)"
        & docker compose -f $composeFile --env-file $envFile up -d
    }
    if ($LASTEXITCODE -ne 0) { throw "docker compose fallo con codigo $LASTEXITCODE" }
    Write-OK "Contenedores iniciados"
} catch {
    Write-Fail "Error al lanzar Docker Compose: $_"
    Write-Host "  Revisa que Docker Desktop este corriendo y vuelve a intentarlo." -ForegroundColor Gray
    exit 1
}

# --- 7. Esperar que Navidrome arranque ----------------------------------------
Write-Step "7" "Esperando que Navidrome arranque"

Write-Info "Esperando hasta 90 segundos..."
$maxWait  = 90
$interval = 5
$elapsed  = 0
$ready    = $false

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$ND_PORT/ping" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Write-Host "  Esperando... ($elapsed s)" -ForegroundColor DarkGray
}

if ($ready) {
    Write-OK "Navidrome esta listo!"
} else {
    Write-Warn "Navidrome tarda mas de lo normal. Puede que aun este arrancando."
    Write-Info "Abre http://localhost:$ND_PORT en el navegador en unos segundos."
}

# --- 8. Crear usuario admin (primera vez) ------------------------------------
if ($WITH_WEBQUEUE -and $ND_ADMIN_USER -and $ready) {
    Write-Step "8" "Configurando usuario admin en Navidrome"
    Write-Info "Abre http://localhost:$ND_PORT en el navegador."
    Write-Info "La primera vez, Navidrome te pedira crear el admin. Usa estos datos:"
    Write-Host ""
    Write-Host "    Usuario:    $ND_ADMIN_USER" -ForegroundColor White
    Write-Host "    Contrasena: $ND_ADMIN_PASS" -ForegroundColor White
    Write-Host ""
    Start-Process "http://localhost:$ND_PORT"
    Read-Host "  Pulsa ENTER cuando hayas creado el usuario en el navegador"
}

# --- 9. Resumen final ---------------------------------------------------------
Write-Host ""
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |        AXCENMUSIC INSTALADO CORRECTAMENTE           |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  DATOS PARA NAVIBEAT (iOS)                          |" -ForegroundColor Green
Write-Host "  |  -------------------------------------------------  |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  |  NaviBeat -> Ajustes -> Agregar servidor            |" -ForegroundColor Green
Write-Host "  |  Tipo: Subsonic / OpenSubsonic                      |" -ForegroundColor Green
Write-Host "  |                                                      |" -ForegroundColor Green

$serverURL = "http://${localIP}:${ND_PORT}"
$pad = " " * [Math]::Max(0, 50 - $serverURL.Length)
Write-Host "  |  URL del servidor:                                   |" -ForegroundColor Green
Write-Host "  |    $serverURL$pad|" -ForegroundColor Cyan
if ($localIP -ne "localhost") {
    $localURL = "http://localhost:$ND_PORT"
    $pad2 = " " * [Math]::Max(0, 50 - $localURL.Length)
    Write-Host "  |    $localURL$pad2|" -ForegroundColor DarkGray
    Write-Host "  |    (la segunda solo funciona en este mismo PC)       |" -ForegroundColor DarkGray
}
Write-Host "  |                                                      |" -ForegroundColor Green

if ($WITH_WEBQUEUE -and $ND_ADMIN_USER) {
    $upad = " " * [Math]::Max(0, 44 - $ND_ADMIN_USER.Length)
    Write-Host "  |  Usuario:    $ND_ADMIN_USER$upad|" -ForegroundColor Green
    Write-Host "  |  Contrasena: (la que configuraste)                  |" -ForegroundColor Green
} else {
    Write-Host "  |  Usuario:    el que crees en la primera apertura    |" -ForegroundColor Green
    Write-Host "  |              -> abre http://localhost:$ND_PORT          |" -ForegroundColor Green
}

Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  INTERFACES WEB                                      |" -ForegroundColor Green
Write-Host "  |    Navidrome : http://localhost:$ND_PORT                 |" -ForegroundColor Green
if ($WITH_WEBQUEUE) {
    Write-Host "  |    WebQueue  : http://localhost:$WEBQUEUE_PORT                 |" -ForegroundColor Green
}
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  CARPETA DE MUSICA                                   |" -ForegroundColor Green
$mpad = " " * [Math]::Max(0, 50 - $MUSIC_DIR.Length)
Write-Host "  |    $MUSIC_DIR$mpad|" -ForegroundColor Cyan
Write-Host "  |                                                      |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  COMANDOS UTILES (PowerShell en esta carpeta)       |" -ForegroundColor Green
Write-Host "  |    .\start-windows.ps1   -- encender                |" -ForegroundColor DarkGray
Write-Host "  |    .\stop-windows.ps1    -- apagar                  |" -ForegroundColor DarkGray
Write-Host "  |    .\update-windows.ps1  -- actualizar Navidrome    |" -ForegroundColor DarkGray
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""

# --- Guardar resumen en NAVIBEAT-DATOS.txt ------------------------------------
$summaryFile = Join-Path $scriptDir "NAVIBEAT-DATOS.txt"
$summaryFecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if ($WITH_WEBQUEUE -and $ND_ADMIN_USER) {
    $summaryCredenciales = "  Usuario          : $ND_ADMIN_USER`r`n  Contrasena       : (la que configuraste)"
} else {
    $summaryCredenciales = "  Usuario          : el que crees en la primera apertura`r`n                     abre http://localhost:${ND_PORT}"
}
if ($WITH_WEBQUEUE) {
    $summaryWebqueue = "  WebQueue (descargas) : http://localhost:${WEBQUEUE_PORT}"
} else {
    $summaryWebqueue = ""
}

$summary = @"
========================================================
  AXCENMUSIC -- Datos de conexion para NaviBeat
  Generado: $summaryFecha
========================================================

DATOS PARA NAVIBEAT (iOS)
--------------------------
Abre NaviBeat -> Ajustes -> Agregar servidor
Selecciona tipo: Subsonic / OpenSubsonic

  URL del servidor : http://${localIP}:${ND_PORT}
  URL (local PC)   : http://localhost:${ND_PORT}
$summaryCredenciales

INTERFACES WEB
--------------
  Navidrome (admin)    : http://localhost:${ND_PORT}
$summaryWebqueue

CARPETA DE MUSICA
-----------------
  $MUSIC_DIR

ETIQUETAR MUSICA (Mp3tag)
--------------------------
  1. Abre Mp3tag
  2. Arrastra la carpeta de musica a la ventana
  3. Edita las columnas: Title, Artist, Album, Year, Track
  4. Caratulas: boton derecho -> Extended Tags -> COVER
  5. Ctrl+S para guardar
  6. En Navidrome: Biblioteca -> Escanear ahora

  Campos clave:
    TITLE   = nombre de la cancion
    ARTIST  = interprete
    ALBUM   = nombre del album
    YEAR    = anio de lanzamiento
    TRACK   = numero de pista
    COVER   = caratula (imagen incrustada en el archivo)

COMANDOS UTILES
---------------
  Ver logs:
    docker logs axcen-navidrome -f

  Parar:
    docker compose -f docker-compose.windows.yml down

  Iniciar:
    docker compose -f docker-compose.windows.yml up -d

  Actualizar Navidrome:
    docker compose -f docker-compose.windows.yml pull
    docker compose -f docker-compose.windows.yml up -d

PASOS PARA NAVIBEAT (primera vez)
-----------------------------------
  1. Descarga NaviBeat en el App Store (iPhone/iPad)
  2. Abre la app -> icono de ajustes (engranaje)
  3. Selecciona Add Server / Agregar servidor
  4. Elige tipo: Subsonic o OpenSubsonic
  5. Rellena:
       Server URL : http://${localIP}:${ND_PORT}
       Username   : tu usuario de Navidrome
       Password   : tu contrasena de Navidrome
  6. Pulsa Test Connection -- debe decir OK
  7. Guarda y disfruta tu musica!

NOTA
----
  - NaviBeat conecta si el iPhone esta en la misma red WiFi que este PC
  - Para acceso desde fuera de casa instala Tailscale en PC + iPhone
  - Si la IP cambia, asigna IP fija al PC en el router (DHCP reservation)

========================================================
"@

Set-Content -Path $summaryFile -Value $summary -Encoding UTF8
Write-Host "  Resumen guardado en:" -ForegroundColor DarkGray
Write-Host "  $summaryFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Abriendo el resumen en Notepad..." -ForegroundColor DarkGray
Start-Process notepad.exe $summaryFile

Write-Host ""
Read-Host "  Pulsa ENTER para salir"
