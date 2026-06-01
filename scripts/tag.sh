#!/usr/bin/env bash
# Etiqueta automáticamente la biblioteca de música con MusicBrainz
# Corrige artista, álbum, año, género, carátula, etc.
#
# Uso:
#   bash scripts/tag.sh              → etiqueta toda la biblioteca
#   bash scripts/tag.sh /ruta/album  → etiqueta solo esa carpeta
#   bash scripts/tag.sh --timid      → solo importa si la coincidencia es muy buena
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

command -v beet &>/dev/null || error "beets no está instalado. Ejecuta: sudo bash scripts/07-setup-beets.sh"

BEETS_DIR="${BEETS_DIR:-/opt/axcenmusic/beets}"
MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
TARGET="${1:-$MUSIC_DIR}"
export BEETSDIR="$BEETS_DIR"

echo ""
echo -e "${BOLD}  AXCENMUSIC — Etiquetado automático con Beets${NC}"
echo ""
echo "  Beets consultará MusicBrainz para cada canción y corregirá:"
echo "    ✓  Artista, álbum, año, género, número de pista"
echo "    ✓  Carátula del álbum (embebida en el archivo)"
echo "    ✓  Nombre del archivo si es necesario"
echo ""
echo -e "  ${YELLOW}IMPORTANTE:${NC} Beets puede modificar los tags de tus archivos."
echo "  No mueve ni borra archivos. Solo escribe metadata."
echo "  Para cada canción, te preguntará si aceptas la coincidencia."
echo ""
echo "  Respuestas rápidas durante la importación:"
echo "    A = Aplicar (aceptar coincidencia)"
echo "    S = Saltar (dejar sin cambios)"
echo "    M = Buscar más opciones"
echo "    U = Usar como está (sin cambios)"
echo ""
read -r -p "  ¿Continuar con el etiquetado de '$TARGET'? [s/N] " CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && { info "Cancelado."; exit 0; }
echo ""

beet import \
  --config "$BEETS_DIR/config.yaml" \
  "$TARGET"

echo ""
info "Etiquetado completado."
info "Ahora ejecuta 'bash scripts/analyze.sh' para analizar BPM y volumen."
