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

VENV="/opt/axcenmusic/venv"

# ── Dependencias del sistema ──────────────────────────────────────
info "Instalando dependencias del sistema..."
apt-get install -y -qq python3-venv python3-dev python3-full ffmpeg \
  libchromaprint-tools chromaprint-tools 2>/dev/null || \
apt-get install -y -qq python3-venv python3-dev python3-full ffmpeg || true

# ── Crear entorno virtual ─────────────────────────────────────────
info "Creando entorno virtual en $VENV..."
python3 -m venv "$VENV"

# ── Instalar beets y plugins en el venv ──────────────────────────
info "Instalando beets y plugins..."
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet \
  beets \
  requests \
  pylast \
  Pillow \
  pyacoustid \
  python-musicbrainzngs

info "Beets $("$VENV/bin/beet" version 2>/dev/null | head -1 || echo 'instalado') listo."

# ── aubio (análisis BPM) ──────────────────────────────────────────
info "Instalando aubio para análisis de BPM..."
"$VENV/bin/pip" install --quiet aubio 2>/dev/null \
  && info "aubio instalado." \
  || warn "aubio no se pudo instalar — el análisis de BPM usará modo básico."

# ── Directorio de trabajo de beets ───────────────────────────────
BEETS_DIR="/opt/axcenmusic/beets"
mkdir -p "$BEETS_DIR"

if [[ ! -f "$BEETS_DIR/config.yaml" ]]; then
  ln -sf "$REPO_DIR/beets/config.yaml" "$BEETS_DIR/config.yaml"
fi

MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
sed -i "s|directory: /mnt/music|directory: $MUSIC_DIR|" "$REPO_DIR/beets/config.yaml"
sed -i "s|library: /opt/axcenmusic/beets/library.db|library: $BEETS_DIR/library.db|" "$REPO_DIR/beets/config.yaml"

mkdir -p "$MUSIC_DIR/Playlists"
chown "${PI_USER:-pi}:${PI_USER:-pi}" "$MUSIC_DIR/Playlists" 2>/dev/null || true
mkdir -p "$REPO_DIR/.cache"

# ── Wrapper axcenbeet (usa el venv) ───────────────────────────────
cat > /usr/local/bin/axcenbeet <<EOF
#!/usr/bin/env bash
BEETSDIR=$BEETS_DIR exec $VENV/bin/beet "\$@"
EOF
chmod +x /usr/local/bin/axcenbeet
info "Comando 'axcenbeet' disponible."

# ── Guardar ruta del venv para otros scripts ──────────────────────
echo "AXCEN_VENV=$VENV" >> "$REPO_DIR/.env" 2>/dev/null || true

info "Setup de beets completado."
echo ""
echo "  Próximos pasos:"
echo "    1. Etiqueta tu biblioteca:  bash $REPO_DIR/scripts/tag.sh"
echo "    2. Analiza BPM/volumen:     bash $REPO_DIR/scripts/analyze.sh"
echo "    3. Genera una playlist DJ:  bash $REPO_DIR/scripts/dj.sh"
echo ""
