#!/usr/bin/env bash
# Analiza toda la biblioteca: BPM y volumen medio de cada canción
# Los resultados se guardan en .cache/music-analysis.csv y los usa dj.sh
#
# Uso:
#   bash scripts/analyze.sh                    → analiza toda la biblioteca
#   bash scripts/analyze.sh /mnt/music/Artista → solo esa carpeta
#   nohup bash scripts/analyze.sh &            → en segundo plano
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

command -v python3 &>/dev/null || error "python3 no encontrado."
command -v ffmpeg  &>/dev/null || error "ffmpeg no encontrado. Ejecuta: sudo bash scripts/06-setup-extras.sh"

MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
TARGET="${1:-$MUSIC_DIR}"
CACHE_DIR="$REPO_DIR/.cache"
CACHE_FILE="$CACHE_DIR/music-analysis.csv"

mkdir -p "$CACHE_DIR"

echo ""
echo -e "${BOLD}  AXCENMUSIC — Análisis de biblioteca${NC}"
echo "  Directorio: $TARGET"
echo "  Caché:      $CACHE_FILE"
echo ""
echo "  Esto puede tardar varios minutos en bibliotecas grandes."
echo "  Si lo cortas a mitad, la próxima vez retoma donde lo dejó."
echo ""

python3 "$REPO_DIR/scripts/analyze.py" \
  "$TARGET" \
  --cache "$CACHE_FILE"

echo ""
info "Análisis guardado en: $CACHE_FILE"
info "Ya puedes ejecutar: bash $REPO_DIR/scripts/dj.sh"
