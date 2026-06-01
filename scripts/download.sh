#!/usr/bin/env bash
# Descarga música desde YouTube, Bandcamp, SoundCloud, etc. directamente en la Pi
# Uso: bash scripts/download.sh 'URL' ['Artista/Album']
#
# Ejemplos:
#   bash scripts/download.sh 'https://youtube.com/watch?v=dQw4w9WgXcQ'
#   bash scripts/download.sh 'https://youtube.com/playlist?list=...' 'Daft Punk/Discovery'
#   bash scripts/download.sh 'https://bandcamp.com/...' 'Artista/Album'
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

notify() {
  [[ -n "${NTFY_TOPIC:-}" ]] || return 0
  curl -s -d "$1" "https://ntfy.sh/${NTFY_TOPIC}" \
    -H "Title: Axcenmusic — Nueva música" \
    -H "Priority: default" \
    -H "Tags: musical_note" \
    &>/dev/null || true
}

command -v yt-dlp &>/dev/null \
  || error "yt-dlp no está instalado. Ejecuta: sudo bash scripts/06-setup-extras.sh"

URL="${1:-}"
SUBFOLDER="${2:-}"
MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"

if [[ -z "$URL" ]]; then
  echo ""
  echo "  Uso: bash scripts/download.sh 'URL' ['Artista/Album']"
  echo ""
  echo "  Ejemplos:"
  echo "    bash scripts/download.sh 'https://youtube.com/watch?v=...'"
  echo "    bash scripts/download.sh 'https://youtube.com/playlist?list=...' 'Daft Punk/Discovery'"
  echo "    bash scripts/download.sh 'https://bandcamp.com/...'"
  echo ""
  exit 1
fi

# Directorio destino: subcarpeta especificada o carpeta 'Descargas'
if [[ -n "$SUBFOLDER" ]]; then
  DEST="$MUSIC_DIR/$SUBFOLDER"
else
  DEST="$MUSIC_DIR/Descargas"
fi
mkdir -p "$DEST"

info "Descargando desde: $URL"
info "Destino: $DEST"
echo ""

yt-dlp \
  --extract-audio \
  --audio-format mp3 \
  --audio-quality 0 \
  --embed-thumbnail \
  --embed-metadata \
  --add-metadata \
  --output "$DEST/%(artist)s - %(title)s.%(ext)s" \
  "$URL"

echo ""
COUNT=$(find "$DEST" -maxdepth 1 -name "*.mp3" 2>/dev/null | wc -l)
info "Descarga completada. Archivos MP3 en $DEST: $COUNT"

# Sugerir buscar letras para los archivos nuevos
info "Consejo: ejecuta 'bash scripts/lyrics.sh \"$DEST\"' para descargar las letras."

# Notificar
FOLDER_NAME=$(basename "$DEST")
notify "Descarga completada en '$FOLDER_NAME' ($COUNT archivos MP3). Escanea la biblioteca en Navidrome."
