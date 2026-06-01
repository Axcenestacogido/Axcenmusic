#!/usr/bin/env bash
# =============================================================
#  PASO 7 — Beets (etiquetado automático) + aubio (análisis BPM)
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

[[ $EUID -ne 0 ]] && { echo "Ejecutar con sudo"; exit 1; }

# ── Dependencias del sistema ──────────────────────────────────────
info "Instalando dependencias del sistema..."
apt-get install -y -qq \
  python3-pip python3-dev \
  libchromaprint-tools \
  ffmpeg \
  chromaprint-tools 2>/dev/null || true

# ── Beets + plugins ──────────────────────────────────────────────
info "Instalando beets y plugins..."
pip3 install --quiet --break-system-packages \
  beets \
  requests \
  pylast \
  Pillow \
  pyacoustid \
  python-musicbrainzngs 2>/dev/null || \
pip3 install --quiet \
  beets \
  requests \
  pylast \
  Pillow \
  pyacoustid \
  python-musicbrainzngs

info "Beets $(beet version 2>/dev/null | head -1) instalado."

# ── aubio (análisis BPM) ──────────────────────────────────────────
info "Instalando aubio para análisis de BPM..."
pip3 install --quiet --break-system-packages aubio 2>/dev/null || \
pip3 install --quiet aubio
info "aubio instalado."

# ── Directorio de trabajo de beets ───────────────────────────────
BEETS_DIR="/opt/axcenmusic/beets"
mkdir -p "$BEETS_DIR"

# Enlazar la config del repo
if [[ ! -f "$BEETS_DIR/config.yaml" ]]; then
  ln -sf "$REPO_DIR/beets/config.yaml" "$BEETS_DIR/config.yaml"
fi

# Sustituir la ruta de la biblioteca por la correcta
MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
sed -i "s|directory: /mnt/music|directory: $MUSIC_DIR|" "$REPO_DIR/beets/config.yaml"
sed -i "s|library: /opt/axcenmusic/beets/library.db|library: $BEETS_DIR/library.db|" "$REPO_DIR/beets/config.yaml"

# Playlist dir
mkdir -p "$MUSIC_DIR/Playlists"
chown "${PI_USER:-pi}:${PI_USER:-pi}" "$MUSIC_DIR/Playlists" 2>/dev/null || true
info "Directorio de playlists: $MUSIC_DIR/Playlists"

# Directorio de caché de análisis
mkdir -p "$REPO_DIR/.cache"

# ── Wrapper beet con config correcta ─────────────────────────────
cat > /usr/local/bin/axcenbeet <<EOF
#!/usr/bin/env bash
# Wrapper de beet con la configuración de Axcenmusic
BEETSDIR=$BEETS_DIR exec beet "\$@"
EOF
chmod +x /usr/local/bin/axcenbeet
info "Comando 'axcenbeet' disponible (equivale a: BEETSDIR=$BEETS_DIR beet ...)"

info "Setup de beets completado."
echo ""
echo "  Próximos pasos:"
echo "    1. Etiqueta tu biblioteca:  bash $REPO_DIR/scripts/tag.sh"
echo "    2. Analiza BPM/volumen:     bash $REPO_DIR/scripts/analyze.sh"
echo "    3. Genera una playlist DJ:  bash $REPO_DIR/scripts/dj.sh"
echo ""
