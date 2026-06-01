#!/usr/bin/env bash
# Descarga letras automáticamente para toda la biblioteca de música
#
# Fuente: lrclib.net (gratuito, sin API key, código abierto)
# Formato: archivos .lrc junto a cada canción → Navidrome los muestra al reproducir
#
# Uso:
#   bash scripts/lyrics.sh                    → toda la biblioteca
#   bash scripts/lyrics.sh /mnt/music/Artista → solo una carpeta
#   bash scripts/lyrics.sh --force            → sobreescribir .lrc existentes
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
found()  { echo -e "  ${GREEN}✓${NC}  $*"; }
skipped(){ echo -e "  ${CYAN}–${NC}  $*"; }
missing(){ echo -e "  ${YELLOW}?${NC}  $*"; }

# Dependencias
for cmd in ffprobe curl jq python3; do
  command -v "$cmd" &>/dev/null \
    || { warn "Falta '$cmd'. Instala con: sudo bash scripts/06-setup-extras.sh"; exit 1; }
done

# Argumentos
FORCE=false
MUSIC_DIR_ARG=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *)       MUSIC_DIR_ARG="$arg" ;;
  esac
done
TARGET="${MUSIC_DIR_ARG:-${MUSIC_DIR:-/mnt/music}}"

urlencode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" -- "$1"
}

FOUND=0; SKIPPED=0; MISSING=0; TOTAL=0

fetch_lyrics() {
  local file="$1"
  local lrc_file="${file%.*}.lrc"
  TOTAL=$((TOTAL + 1))

  # Saltar si ya existe y no se fuerza sobreescritura
  if [[ -f "$lrc_file" && "$FORCE" == "false" ]]; then
    skipped "$(basename "$file")  (ya tiene .lrc)"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  # Leer tags con ffprobe
  local title artist album duration
  title=$(   ffprobe -v quiet -show_entries format_tags=title   -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 || echo "")
  artist=$(  ffprobe -v quiet -show_entries format_tags=artist  -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 || echo "")
  album=$(   ffprobe -v quiet -show_entries format_tags=album   -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 || echo "")
  duration=$(ffprobe -v quiet -show_entries format=duration     -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1 2>/dev/null || echo "0")

  if [[ -z "$title" ]]; then
    missing "$(basename "$file")  (sin tag de título — no se puede buscar)"
    MISSING=$((MISSING + 1))
    return
  fi

  # Construir URL de la API
  local api_url response http_code body
  if [[ -n "$artist" ]]; then
    # Búsqueda exacta con artista + título + duración
    api_url="https://lrclib.net/api/get"
    api_url+="?artist_name=$(urlencode "$artist")"
    api_url+="&track_name=$(urlencode "$title")"
    api_url+="&album_name=$(urlencode "$album")"
    api_url+="&duration=${duration}"
    response=$(curl -s -w "\n%{http_code}" --max-time 10 "$api_url" 2>/dev/null || echo -e "\n000")
    http_code=$(printf '%s' "$response" | tail -1)
    body=$(printf '%s' "$response" | head -n -1)
  fi

  # Si no hay artista o no se encontró, buscar solo por título
  if [[ -z "$artist" || "$http_code" == "404" || "$http_code" == "000" ]]; then
    api_url="https://lrclib.net/api/search?track_name=$(urlencode "$title")"
    response=$(curl -s -w "\n%{http_code}" --max-time 10 "$api_url" 2>/dev/null || echo -e "\n000")
    http_code=$(printf '%s' "$response" | tail -1)
    # /api/search devuelve un array — tomar el primer resultado
    body=$(printf '%s' "$response" | head -n -1 | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(json.dumps(data[0]) if data else '{}')
except Exception:
    print('{}')
")
  fi

  if [[ "$http_code" != "200" ]]; then
    missing "$(basename "$file")  (no encontrada — código $http_code)"
    MISSING=$((MISSING + 1))
    return
  fi

  local synced plain
  synced=$(echo "$body" | jq -r '.syncedLyrics // empty' 2>/dev/null || echo "")
  plain=$(echo  "$body" | jq -r '.plainLyrics  // empty' 2>/dev/null || echo "")

  if [[ -n "$synced" ]]; then
    echo "$synced" > "$lrc_file"
    found "$(basename "$file")  →  .lrc  ${CYAN}(sincronizada)${NC}"
    FOUND=$((FOUND + 1))
  elif [[ -n "$plain" ]]; then
    echo "$plain" > "$lrc_file"
    found "$(basename "$file")  →  .lrc  (sin marcas de tiempo)"
    FOUND=$((FOUND + 1))
  else
    missing "$(basename "$file")  (sin letra disponible en lrclib.net)"
    MISSING=$((MISSING + 1))
  fi

  # Pausa para no saturar la API
  sleep 0.4
}

echo ""
echo -e "${BOLD}  AXCENMUSIC — Descarga automática de letras${NC}"
echo    "  Fuente: lrclib.net (gratuito, sin API key)"
echo    "  Directorio: $TARGET"
[[ "$FORCE" == "true" ]] && echo "  Modo: sobreescribir .lrc existentes"
echo ""

# Procesar archivos (process substitution mantiene el shell para que los contadores funcionen)
while IFS= read -r -d '' file; do
  fetch_lyrics "$file"
done < <(find "$TARGET" -type f \( \
  -iname "*.mp3"  -o \
  -iname "*.flac" -o \
  -iname "*.m4a"  -o \
  -iname "*.ogg"  -o \
  -iname "*.opus" \
\) -print0 2>/dev/null | sort -z)

echo ""
echo -e "${BOLD}  Resultado:${NC}"
echo "    ✓  $FOUND letras descargadas"
echo "    –  $SKIPPED ya tenían .lrc (usa --force para sobreescribir)"
echo "    ?  $MISSING no encontradas"
echo "    Total: $TOTAL canciones procesadas"
echo ""
[[ $FOUND -gt 0 ]] && info "Navidrome mostrará las letras automáticamente al reproducir."
