#!/usr/bin/env bash
# ================================================================
#  AXCENMUSIC — Instalador interactivo
#
#  Uso desde el repo clonado:
#    sudo bash install.sh
#
#  O directamente desde internet:
#    curl -fsSL https://raw.githubusercontent.com/Axcenestacogido/Axcenmusic/main/install.sh | sudo bash
# ================================================================
set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}  ✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $*"; }
error() { echo -e "${RED}  ✗  ERROR:${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}  ══════════════════════════════════════${NC}"; \
           echo -e "${BOLD}${BLUE}  $*${NC}"; \
           echo -e "${BOLD}${BLUE}  ══════════════════════════════════════${NC}\n"; }

# Lee una línea desde el terminal aunque el script venga por pipe (curl)
ask() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    printf "  ${CYAN}?${NC}  %s ${YELLOW}[%s]${NC}: " "$prompt" "$default" >&2
  else
    printf "  ${CYAN}?${NC}  %s: " "$prompt" >&2
  fi
  local result
  IFS= read -r result < /dev/tty 2>/dev/null || result=""
  printf '%s' "${result:-$default}"
}

ask_secret() {
  local prompt="$1"
  printf "  ${CYAN}?${NC}  %s: " "$prompt" >&2
  local result
  IFS= read -rs result < /dev/tty 2>/dev/null || result=""
  printf '\n' >&2
  printf '%s' "$result"
}

# ── Root ─────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Ejecutar con sudo:\n    sudo bash install.sh"

# ── Instalar git si falta ─────────────────────────────────────────
if ! command -v git &>/dev/null; then
  echo "  Instalando git..."
  apt-get update -qq && apt-get install -y -qq git
fi

# ── Localizar o clonar el repositorio ────────────────────────────
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
REPO_DIR=""

if [[ -n "$SCRIPT_PATH" && -f "$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)/docker-compose.yml" ]]; then
  REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
elif [[ -f "$(pwd)/docker-compose.yml" && -d "$(pwd)/scripts" ]]; then
  REPO_DIR="$(pwd)"
else
  REPO_DIR="/opt/axcenmusic"
  REPO_URL="https://github.com/Axcenestacogido/Axcenmusic.git"

  if [[ -d "$REPO_DIR/.git" ]]; then
    info "Actualizando repositorio en $REPO_DIR..."
    git -C "$REPO_DIR" pull --ff-only origin main 2>/dev/null || true
  else
    info "Clonando repositorio en $REPO_DIR..."
    # Primer intento sin credenciales (repo público)
    if ! git clone "$REPO_URL" "$REPO_DIR" 2>/dev/null; then
      echo ""
      warn "El clone falló. Si el repositorio es privado, introduce un"
      warn "Personal Access Token (PAT) de GitHub para continuar."
      echo ""
      echo "   Cómo generar un PAT:"
      echo "   → GitHub > Settings > Developer settings > Personal access tokens"
      echo "   → Permisos necesarios: Contents (read)"
      echo ""
      GH_TOKEN=$(ask_secret "GitHub Personal Access Token (se usará solo para clonar)")
      if [[ -z "$GH_TOKEN" ]]; then
        error "No se proporcionó token. Clona el repo manualmente y vuelve a ejecutar install.sh desde dentro."
      fi
      # Extrae host y ruta del URL para insertar el token
      REPO_URL_AUTH="${REPO_URL/https:\/\//https://x-access-token:${GH_TOKEN}@}"
      git clone "$REPO_URL_AUTH" "$REPO_DIR" \
        || error "Clone fallido incluso con token. Verifica que el PAT tenga acceso al repo."
      # Elimina el token del remote para no dejarlo en git config
      git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
      info "Repositorio clonado. Token eliminado del remote."
    fi
  fi
fi

SCRIPTS_DIR="$REPO_DIR/scripts"

# ── Banner ────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${BOLD}${GREEN}"
echo "   ╔═══════════════════════════════════════════════════════╗"
echo "   ║        AXCENMUSIC — Instalador interactivo            ║"
echo "   ║    Servidor de música personal en Raspberry Pi        ║"
echo "   ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "   Configurará automáticamente:"
echo "     ✓  Sistema base + dependencias"
echo "     ✓  Docker + Navidrome  (servidor de música)"
echo "     ✓  Tailscale           (VPN, acceso remoto seguro)"
echo "     ✓  SFTP                (subir música desde el iPhone)"
echo ""
echo "   Responde las preguntas. Pulsa ENTER para el valor por defecto."
echo "   Duración estimada: 10-20 minutos."
echo ""

# ══════════════════════════════════════════════════════════════════
#  WIZARD DE CONFIGURACIÓN
# ══════════════════════════════════════════════════════════════════

# ── 1/5 TAILSCALE ────────────────────────────────────────────────
step "1/5  Tailscale  (VPN)"
echo "   Tailscale crea una red privada para acceder a esta Pi"
echo "   desde el iPhone en cualquier parte del mundo."
echo ""

TAILSCALE_HOSTNAME=$(ask "Nombre de la Pi en tu red Tailscale" "pimusic")

echo ""
echo "   La 'auth key' conecta automáticamente sin abrir un navegador."
echo "   Genera una en: https://login.tailscale.com/admin/settings/keys"
echo "   (reusable: No  |  expiry: 90 días)"
echo "   Déjala vacía para autenticar manualmente una vez instalado."
echo ""

TAILSCALE_AUTH_KEY=$(ask "Auth key de Tailscale" "")
[[ -z "$TAILSCALE_AUTH_KEY" ]] && TAILSCALE_AUTH_KEY="tskey-auth-RELLENAR"

# ── 2/5 ALMACENAMIENTO ───────────────────────────────────────────
step "2/5  Almacenamiento de música"

STORAGE_UUID="RELLENAR_CON_BLKID"
STORAGE_FSTYPE="ext4"
MUSIC_DIR="/mnt/music"

echo "   Particiones disponibles en este sistema:"
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT 2>/dev/null || true
echo ""

# Filtra particiones que no sean el sistema raíz ni boot
mapfile -t PARTS < <(
  lsblk -rno NAME,TYPE,MOUNTPOINT 2>/dev/null \
  | awk '$2=="part" && $3!="/" && $3!="/boot" && $3!="/boot/firmware" && $3!="[SWAP]" {print "/dev/"$1}' \
  || true
)

if [[ ${#PARTS[@]} -gt 0 ]]; then
  echo "   Elige la partición donde guardarás tu música:"
  echo ""
  for i in "${!PARTS[@]}"; do
    DEV="${PARTS[$i]}"
    SIZE=$(lsblk -rno SIZE   "$DEV" 2>/dev/null || echo "?")
    FS=$(  lsblk -rno FSTYPE "$DEV" 2>/dev/null || echo "?")
    LBL=$( lsblk -rno LABEL  "$DEV" 2>/dev/null || echo "-")
    printf "     %d)  %-12s  %6s  %-8s  %s\n" "$((i+1))" "$DEV" "$SIZE" "$FS" "$LBL"
  done
  LAST=$((${#PARTS[@]}+1))
  printf "     %d)  Sin almacenamiento externo (usar la propia SD)\n\n" "$LAST"

  SEL=$(ask "Número de partición" "$LAST")

  if [[ "$SEL" =~ ^[0-9]+$ && "$SEL" -ge 1 && "$SEL" -le "${#PARTS[@]}" ]]; then
    SELECTED_DEV="${PARTS[$((SEL-1))]}"
    UUID_DET=$(  blkid -s UUID -o value "$SELECTED_DEV" 2>/dev/null || true)
    FSTYPE_DET=$(blkid -s TYPE -o value "$SELECTED_DEV" 2>/dev/null || echo "ext4")

    if [[ -n "$UUID_DET" ]]; then
      STORAGE_UUID="$UUID_DET"
      STORAGE_FSTYPE="$FSTYPE_DET"
      info "UUID detectado: $STORAGE_UUID  ($STORAGE_FSTYPE)"
    else
      warn "No se pudo detectar el UUID de $SELECTED_DEV automáticamente."
      STORAGE_UUID=$(ask "UUID del dispositivo (cópialo de blkid)" "RELLENAR_CON_BLKID")
      STORAGE_FSTYPE=$(ask "Tipo de sistema de ficheros" "ext4")
    fi
  else
    info "Sin almacenamiento externo — la música se guardará en la SD."
  fi
fi

echo ""
MUSIC_DIR=$(ask "Ruta de montaje para la música" "/mnt/music")

# ── 3/5 SFTP ─────────────────────────────────────────────────────
step "3/5  Contraseña SFTP"
echo "   Se creará el usuario 'musicupload' para subir música"
echo "   desde el iPhone con FE File Explorer, Owlfiles, etc."
echo ""

SFTP_PASSWORD=""
while true; do
  P1=$(ask_secret "Contraseña para 'musicupload'")
  P2=$(ask_secret "Repite la contraseña")
  if [[ -n "$P1" && "$P1" == "$P2" ]]; then
    SFTP_PASSWORD="$P1"
    info "Contraseña registrada."
    break
  fi
  warn "Las contraseñas no coinciden o están vacías. Inténtalo de nuevo."
  echo ""
done

# ── 4/5 NAVIDROME ────────────────────────────────────────────────
step "4/5  Navidrome"

ND_PORT=$(ask "Puerto de Navidrome" "4533")
ND_SCAN_SCHEDULE=$(ask "Frecuencia de escaneo  (@every 1h / @daily / 0=desactivado)" "@every 1h")

# ── 5/5 SSH ──────────────────────────────────────────────────────
step "5/5  SSH"

SSH_PORT=$(ask "Puerto SSH" "22")
PI_USER=$(ask "Usuario principal de la Pi" "pi")

# ── Resumen antes de instalar ─────────────────────────────────────
echo ""
echo -e "${BOLD}   ┌─────────────────────────────────────────────────────┐"
echo    "   │           RESUMEN DE CONFIGURACIÓN                   │"
echo    "   ├─────────────────────────────────────────────────────┤"
printf  "   │  %-22s  %-28s│\n" "Hostname Tailscale:"  "$TAILSCALE_HOSTNAME"
printf  "   │  %-22s  %-28s│\n" "Auth key:"            "${TAILSCALE_AUTH_KEY:0:28}"
printf  "   │  %-22s  %-28s│\n" "Música en:"           "$MUSIC_DIR"
printf  "   │  %-22s  %-28s│\n" "UUID almacenamiento:" "${STORAGE_UUID:0:28}"
printf  "   │  %-22s  %-28s│\n" "Filesystem:"          "$STORAGE_FSTYPE"
printf  "   │  %-22s  %-28s│\n" "Puerto Navidrome:"    "$ND_PORT"
printf  "   │  %-22s  %-28s│\n" "Escaneo música:"      "$ND_SCAN_SCHEDULE"
printf  "   │  %-22s  %-28s│\n" "Puerto SSH:"          "$SSH_PORT"
printf  "   │  %-22s  %-28s│\n" "Usuario Pi:"          "$PI_USER"
echo -e "   └─────────────────────────────────────────────────────┘${NC}"
echo ""

CONFIRM=$(ask "¿Iniciar instalación?" "s")
[[ "${CONFIRM,,}" != "s" ]] && { info "Instalación cancelada."; exit 0; }

# ══════════════════════════════════════════════════════════════════
#  GENERAR .env
# ══════════════════════════════════════════════════════════════════
ENV_FILE="$REPO_DIR/.env"
info "Generando $ENV_FILE..."

cat > "$ENV_FILE" <<EOF
# ==============================================================
#  AXCENMUSIC — Configuración generada por install.sh
#  Fecha: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================

# --- ALMACENAMIENTO ---
MUSIC_DIR=$MUSIC_DIR
STORAGE_UUID=$STORAGE_UUID
STORAGE_FSTYPE=$STORAGE_FSTYPE

# --- NAVIDROME ---
ND_PORT=$ND_PORT
ND_DATA_DIR=./navidrome-data
ND_SCAN_SCHEDULE=$ND_SCAN_SCHEDULE
ND_LOG_LEVEL=info
ND_SESSION_TIMEOUT=24h

# --- TAILSCALE ---
TAILSCALE_AUTH_KEY=$TAILSCALE_AUTH_KEY
TAILSCALE_HOSTNAME=$TAILSCALE_HOSTNAME

# --- SSH / SFTP ---
SSH_PORT=$SSH_PORT
PI_USER=$PI_USER
EOF

info ".env generado correctamente."

# ══════════════════════════════════════════════════════════════════
#  EJECUTAR INSTALACIÓN
# ══════════════════════════════════════════════════════════════════
export SFTP_PASSWORD
cd "$REPO_DIR"

run_step() {
  local label="$1" script="$2"
  echo ""
  echo -e "${BOLD}${BLUE}  ──────────────────────────────────────────────────────${NC}"
  info "$label"
  echo -e "${BOLD}${BLUE}  ──────────────────────────────────────────────────────${NC}"
  bash "$SCRIPTS_DIR/$script"
}

run_step "Paso 1/5 — Sistema base"      "01-system-setup.sh"
run_step "Paso 2/5 — Docker"            "02-install-docker.sh"
run_step "Paso 3/5 — Navidrome"         "03-deploy-navidrome.sh"
run_step "Paso 4/5 — Tailscale"         "04-install-tailscale.sh"
run_step "Paso 5/5 — SFTP"             "05-setup-sftp.sh"

# ══════════════════════════════════════════════════════════════════
#  RESUMEN FINAL
# ══════════════════════════════════════════════════════════════════
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}"
echo "   ╔═══════════════════════════════════════════════════════╗"
echo "   ║         INSTALACIÓN COMPLETADA — AXCENMUSIC           ║"
echo "   ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

cat <<SUMMARY
   ┌─── NAVIDROME (servidor de música) ────────────────────────┐
   │
   │   http://${TAILSCALE_HOSTNAME}:${ND_PORT}
   │   http://${TAILSCALE_IP}:${ND_PORT}
   │
   │   → Abre en el iPhone y crea tu cuenta admin
   │
   └────────────────────────────────────────────────────────────┘

   ┌─── SFTP (subir música desde iPhone) ──────────────────────┐
   │
   │   Host:        ${TAILSCALE_HOSTNAME}
   │               (o ${TAILSCALE_IP})
   │   Puerto:      ${SSH_PORT}
   │   Usuario:     musicupload
   │   Directorio:  /music
   │
   └────────────────────────────────────────────────────────────┘

   ┌─── App iOS — Amperfy / NaviBeat ──────────────────────────┐
   │
   │   Servidor:    http://${TAILSCALE_HOSTNAME}:${ND_PORT}
   │   Protocolo:   OpenSubsonic
   │   Usuario:     el que crees en Navidrome
   │
   └────────────────────────────────────────────────────────────┘

   ┌─── Comandos de mantenimiento ──────────────────────────────┐
   │
   │   Logs:       sudo journalctl -u axcenmusic -f
   │   Reiniciar:  sudo systemctl restart axcenmusic
   │   Estado:     sudo systemctl status axcenmusic
   │   VPN:        tailscale status
   │   Disco:      df -h ${MUSIC_DIR}
   │
   └────────────────────────────────────────────────────────────┘

SUMMARY

info "Checklist de verificación: ${REPO_DIR}/docs/checklist.md"
echo ""
