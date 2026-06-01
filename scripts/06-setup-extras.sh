#!/usr/bin/env bash
# =============================================================
#  PASO 6 — Extras: yt-dlp, ffmpeg, backup automático, ntfy.sh
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ── yt-dlp ────────────────────────────────────────────────────────
info "Instalando yt-dlp..."
curl -fsSL \
  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
  -o /usr/local/bin/yt-dlp
chmod +x /usr/local/bin/yt-dlp
info "yt-dlp $(yt-dlp --version) instalado."

# ── ffmpeg (necesario para yt-dlp y lyrics.sh) ───────────────────
if ! command -v ffmpeg &>/dev/null; then
  info "Instalando ffmpeg..."
  apt-get install -y -qq ffmpeg
fi
info "ffmpeg $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}') disponible."

# ── Permisos de ejecución en todos los scripts ───────────────────
info "Asignando permisos de ejecución a los scripts..."
chmod +x "$REPO_DIR"/scripts/*.sh

# ── Cron: backup diario a las 3 AM ───────────────────────────────
CRON_FILE="/etc/cron.d/axcenmusic"
info "Configurando cron de backup diario (3:00 AM)..."
cat > "$CRON_FILE" <<EOF
# Axcenmusic — backup diario de Navidrome a las 3:00 AM
0 3 * * * root bash $REPO_DIR/scripts/backup.sh >> /var/log/axcenmusic-backup.log 2>&1
EOF
chmod 644 "$CRON_FILE"
info "Cron configurado: $CRON_FILE"

# ── ntfy.sh: notificación de prueba ──────────────────────────────
if [[ -n "${NTFY_TOPIC:-}" && "$NTFY_TOPIC" != "RELLENAR" ]]; then
  info "Enviando notificación de prueba al topic '${NTFY_TOPIC}'..."
  if curl -s \
    -d "Axcenmusic instalado correctamente en $(hostname). ¡Todo listo!" \
    "https://ntfy.sh/${NTFY_TOPIC}" \
    -H "Title: Axcenmusic" \
    -H "Priority: default" \
    -H "Tags: white_check_mark" \
    &>/dev/null; then
    info "Notificación enviada. Comprueba la app ntfy en tu iPhone."
  else
    warn "No se pudo enviar la notificación de prueba (¿hay conexión?)."
  fi
else
  warn "NTFY_TOPIC no configurado — notificaciones desactivadas."
  warn "Añade NTFY_TOPIC=tu-topic a .env y reinstala este paso para activarlas."
fi

info "Extras instalados correctamente."
echo ""
echo "  Scripts disponibles:"
echo "    bash $REPO_DIR/scripts/status.sh              → estado general"
echo "    sudo bash $REPO_DIR/scripts/update.sh         → actualizar Navidrome"
echo "    sudo bash $REPO_DIR/scripts/backup.sh         → backup manual"
echo "    bash $REPO_DIR/scripts/download.sh 'URL'      → descargar música"
echo "    bash $REPO_DIR/scripts/lyrics.sh              → descargar letras"
echo ""
