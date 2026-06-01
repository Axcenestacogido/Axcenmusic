#!/usr/bin/env bash
# =============================================================
#  PASO 1 — Preparación del sistema
#  - Actualiza paquetes
#  - Configura hostname
#  - Instala dependencias base
#  - Monta el almacenamiento de música (HDD externo o microSD)
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- Actualizar sistema ----
info "Actualizando lista de paquetes..."
apt-get update -qq

info "Actualizando paquetes instalados..."
apt-get upgrade -y -qq

info "Instalando dependencias base..."
apt-get install -y -qq \
  curl wget git vim nano \
  htop iotop \
  exfat-fuse exfatprogs \
  ntfs-3g \
  usbutils \
  avahi-daemon avahi-utils \
  jq

# ---- Hostname ----
HOSTNAME_TARGET="${TAILSCALE_HOSTNAME:-pimusic}"
CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" != "$HOSTNAME_TARGET" ]]; then
  info "Estableciendo hostname: $HOSTNAME_TARGET"
  echo "$HOSTNAME_TARGET" > /etc/hostname
  sed -i "s/$CURRENT_HOSTNAME/$HOSTNAME_TARGET/g" /etc/hosts
  hostname "$HOSTNAME_TARGET"
else
  info "Hostname ya es '$HOSTNAME_TARGET', sin cambios."
fi

# ---- Zona horaria ----
info "Configurando zona horaria (Europe/Madrid)..."
timedatectl set-timezone Europe/Madrid || warn "No se pudo configurar zona horaria, continúa manualmente."

# ---- Directorio de música ----
MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
info "Creando punto de montaje: $MUSIC_DIR"
mkdir -p "$MUSIC_DIR"
chown "${PI_USER:-pi}:${PI_USER:-pi}" "$MUSIC_DIR"

# ---- Montar almacenamiento ----
if [[ -z "${STORAGE_UUID:-}" || "$STORAGE_UUID" == "RELLENAR_CON_BLKID" ]]; then
  warn "STORAGE_UUID no está configurado en .env"
  warn "Dispositivos disponibles:"
  echo ""
  lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
  echo ""
  warn "Cuando identifiques tu dispositivo, añade su UUID al .env"
  warn "y ejecuta manualmente: sudo bash scripts/01-system-setup.sh"
  warn "O monta manualmente ahora: sudo mount /dev/sdX1 $MUSIC_DIR"
  warn "Continuando sin montar almacenamiento..."
else
  FSTYPE="${STORAGE_FSTYPE:-ext4}"
  FSTAB_ENTRY="UUID=${STORAGE_UUID}  ${MUSIC_DIR}  ${FSTYPE}  defaults,nofail,noatime  0  2"

  if grep -q "$STORAGE_UUID" /etc/fstab; then
    info "Entrada fstab ya existe para UUID=$STORAGE_UUID"
  else
    info "Añadiendo entrada al fstab para montaje automático..."
    echo "" >> /etc/fstab
    echo "# Axcenmusic - almacenamiento de música" >> /etc/fstab
    echo "$FSTAB_ENTRY" >> /etc/fstab
    info "Fstab actualizado."
  fi

  info "Montando $MUSIC_DIR..."
  mount -a || warn "Error al montar — verifica UUID y tipo de FS en .env"

  if mountpoint -q "$MUSIC_DIR"; then
    info "Almacenamiento montado correctamente en $MUSIC_DIR"
    df -h "$MUSIC_DIR"
  else
    warn "$MUSIC_DIR no está montado. El servidor arrancará pero sin música."
  fi
fi

# ---- Permisos SSH ----
SSH_PORT="${SSH_PORT:-22}"
if [[ "$SSH_PORT" != "22" ]]; then
  info "Cambiando puerto SSH a $SSH_PORT..."
  sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
  sed -i "s/^Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
  systemctl restart ssh || true
fi

# ---- Habilitar SFTP en sshd ----
info "Verificando configuración SFTP en sshd..."
if ! grep -q "Subsystem sftp" /etc/ssh/sshd_config; then
  echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config
  systemctl restart ssh
fi

info "Sistema preparado correctamente."
