#!/usr/bin/env bash
# =============================================================
#  PASO 5 — Configuración de SFTP para subida de música
#  desde iPhone (FE File Explorer, Owlfiles, etc.)
#
#  Estrategia: SSH ya tiene SFTP integrado. Este script
#  crea un usuario dedicado 'musicupload' con acceso chroot
#  al directorio de música, para no exponer el sistema completo.
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
SFTP_USER="musicupload"
SFTP_GROUP="sftpusers"
SSH_PORT="${SSH_PORT:-22}"

# ---- Crear grupo SFTP ----
if ! getent group "$SFTP_GROUP" &>/dev/null; then
  info "Creando grupo '$SFTP_GROUP'..."
  groupadd "$SFTP_GROUP"
fi

# ---- Crear usuario dedicado ----
if ! id "$SFTP_USER" &>/dev/null; then
  info "Creando usuario '$SFTP_USER'..."
  useradd \
    --shell /sbin/nologin \
    --home-dir /home/$SFTP_USER \
    --create-home \
    --gid "$SFTP_GROUP" \
    "$SFTP_USER"
fi

# ---- Contraseña para el usuario SFTP ----
if [[ -n "${SFTP_PASSWORD:-}" ]]; then
  info "Estableciendo contraseña para '$SFTP_USER'..."
  echo "$SFTP_USER:$SFTP_PASSWORD" | chpasswd
else
  echo ""
  warn "Establece una contraseña para el usuario SFTP '$SFTP_USER':"
  warn "Esta es la contraseña que usarás desde el iPhone para subir música."
  passwd "$SFTP_USER"
fi

# ---- Estructura de directorios para chroot ----
# El directorio raíz del chroot debe ser propiedad de root:root
SFTP_CHROOT="/home/$SFTP_USER"
chown root:root "$SFTP_CHROOT"
chmod 755 "$SFTP_CHROOT"

# Punto de montaje accesible dentro del chroot
SFTP_MUSIC_BIND="$SFTP_CHROOT/music"
mkdir -p "$SFTP_MUSIC_BIND"
chown "$SFTP_USER:$SFTP_GROUP" "$SFTP_MUSIC_BIND"

# ---- Bind mount: $SFTP_MUSIC_BIND -> $MUSIC_DIR ----
FSTAB_BIND="$MUSIC_DIR  $SFTP_MUSIC_BIND  none  bind  0  0"
if grep -q "$SFTP_MUSIC_BIND" /etc/fstab; then
  info "Bind mount ya existe en fstab."
else
  info "Añadiendo bind mount al fstab..."
  echo "" >> /etc/fstab
  echo "# Axcenmusic - SFTP bind mount" >> /etc/fstab
  echo "$FSTAB_BIND" >> /etc/fstab
fi
mount --bind "$MUSIC_DIR" "$SFTP_MUSIC_BIND" 2>/dev/null || \
  warn "No se pudo hacer bind mount ahora (se hará al arrancar si el disco está montado)."

# ---- Configurar sshd para SFTP chroot ----
SSHD_CONF="/etc/ssh/sshd_config"
SFTP_BLOCK="
# === Axcenmusic SFTP ===
Match Group $SFTP_GROUP
    ChrootDirectory /home/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
"

if grep -q "Axcenmusic SFTP" "$SSHD_CONF"; then
  info "Configuración SFTP ya presente en sshd_config."
else
  info "Añadiendo bloque SFTP a sshd_config..."
  # Asegurar que internal-sftp está como subsistema
  if grep -q "^Subsystem sftp" "$SSHD_CONF"; then
    sed -i 's|^Subsystem sftp.*|Subsystem sftp internal-sftp|' "$SSHD_CONF"
  else
    echo "Subsystem sftp internal-sftp" >> "$SSHD_CONF"
  fi
  echo "$SFTP_BLOCK" >> "$SSHD_CONF"
fi

# ---- Reiniciar SSH ----
info "Reiniciando servicio SSH..."
systemctl restart ssh

# ---- Resumen ----
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
info "SFTP configurado correctamente."
echo ""
echo "┌──────────────────────────────────────────────────────┐"
echo "│   DATOS DE CONEXIÓN SFTP (para iPhone)               │"
echo "├──────────────────────────────────────────────────────┤"
echo "│   Host:      ${TAILSCALE_IP} (o nombre Tailscale)    │"
echo "│   Puerto:    ${SSH_PORT}                             │"
echo "│   Usuario:   ${SFTP_USER}                            │"
echo "│   Contraseña: la que acabas de establecer            │"
echo "│   Directorio: /music                                 │"
echo "└──────────────────────────────────────────────────────┘"
echo ""
echo "  Organización recomendada de carpetas:"
echo "    /music/Artista/Album/cancion.flac"
echo "    /music/Artista/Album/cancion.mp3"
echo ""
warn "Navidrome escaneará las carpetas automáticamente según ND_SCAN_SCHEDULE."
warn "Para forzar un escaneo inmediato: ve a Navidrome > ícono usuario > Escanear biblioteca."
