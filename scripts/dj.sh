#!/usr/bin/env bash
# DJ automático — genera playlists inteligentes a partir de tu música
# Usa los datos de BPM y volumen analizados por analyze.sh
#
# Uso:
#   bash scripts/dj.sh              → asistente interactivo
#   bash scripts/dj.sh chill 60    → playlist "chill" de 60 canciones
#   bash scripts/dj.sh workout 50
#
# Modos: chill | tranquilo | normal | animado | workout | mezcla
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}  ✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $*"; }
error() { echo -e "${RED}  ✗${NC}  $*" >&2; exit 1; }

MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
CACHE_FILE="$REPO_DIR/.cache/music-analysis.csv"
PLAYLIST_DIR="$MUSIC_DIR/Playlists"

mkdir -p "$PLAYLIST_DIR"

echo ""
echo -e "${BOLD}  AXCENMUSIC — DJ Automático${NC}"
echo ""

# ── Verificar caché ───────────────────────────────────────────────
if [[ ! -f "$CACHE_FILE" || $(wc -l < "$CACHE_FILE") -le 1 ]]; then
  warn "No hay datos de análisis todavía."
  echo ""
  echo "  Primero ejecuta el analizador para obtener BPM y volumen de tu música:"
  echo ""
  echo "    bash $REPO_DIR/scripts/analyze.sh"
  echo ""
  echo "  (Puede tardar unos minutos según el tamaño de tu biblioteca)"
  echo ""

  # Fallback: playlist aleatoria sin análisis
  read -r -p "  ¿Crear una playlist aleatoria sin análisis? [s/N] " RAND
  if [[ "${RAND,,}" == "s" ]]; then
    TIMESTAMP=$(date '+%Y%m%d_%H%M')
    OUT="$PLAYLIST_DIR/DJ-Aleatorio-${TIMESTAMP}.m3u"
    echo "#EXTM3U" > "$OUT"
    find "$MUSIC_DIR" -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" -o -iname "*.opus" \) \
      | shuf | head -50 \
      | while read -r f; do
          echo "#EXTINF:-1,$(basename "${f%.*}")"
          echo "${f#$MUSIC_DIR/}"
        done >> "$OUT"
    info "Playlist aleatoria creada: $(basename "$OUT")"
    info "Escanea la biblioteca en Navidrome para que aparezca."
  fi
  exit 0
fi

TOTAL_SONGS=$(tail -n +2 "$CACHE_FILE" | wc -l)
echo "  Canciones analizadas: $TOTAL_SONGS"
echo ""

# ── Seleccionar modo ──────────────────────────────────────────────
MODE="${1:-}"
COUNT="${2:-50}"

if [[ -z "$MODE" ]]; then
  echo "  ¿Qué ambiente quieres para la playlist?"
  echo ""
  echo -e "    ${CYAN}1)${NC} Chill / Relajado    — BPM bajo, música tranquila"
  echo -e "    ${CYAN}2)${NC} Tranquilo            — BPM medio-bajo, concentración"
  echo -e "    ${CYAN}3)${NC} Normal / Variado     — BPM medio, para todo"
  echo -e "    ${CYAN}4)${NC} Animado / Fiesta     — BPM alto, buena energía"
  echo -e "    ${CYAN}5)${NC} Workout / Intenso    — BPM muy alto, máxima energía"
  echo -e "    ${CYAN}6)${NC} Mezcla total         — todos los BPMs mezclados"
  echo ""
  read -r -p "  Elige [1-6]: " SEL
  case "$SEL" in
    1) MODE="chill"    ;;
    2) MODE="tranquilo" ;;
    3) MODE="normal"   ;;
    4) MODE="animado"  ;;
    5) MODE="workout"  ;;
    6) MODE="mezcla"   ;;
    *) error "Opción no válida." ;;
  esac
  echo ""
  read -r -p "  Número de canciones [50]: " COUNT_INPUT
  COUNT="${COUNT_INPUT:-50}"
fi

# ── Criterios por modo (BPM min, BPM max, nombre) ────────────────
case "${MODE,,}" in
  chill)     BPM_MIN=0;   BPM_MAX=85;  LABEL="Chill"    ;;
  tranquilo) BPM_MIN=60;  BPM_MAX=105; LABEL="Tranquilo" ;;
  normal)    BPM_MIN=90;  BPM_MAX=130; LABEL="Normal"   ;;
  animado)   BPM_MIN=115; BPM_MAX=155; LABEL="Animado"  ;;
  workout)   BPM_MIN=135; BPM_MAX=999; LABEL="Workout"  ;;
  mezcla)    BPM_MIN=0;   BPM_MAX=999; LABEL="Mezcla"   ;;
  *) error "Modo desconocido: $MODE. Usa: chill tranquilo normal animado workout mezcla" ;;
esac

echo "  Modo:    $LABEL"
echo "  BPM:     ${BPM_MIN}-${BPM_MAX}"
echo "  Canciones: $COUNT"
echo ""

# ── Filtrar y ordenar con awk ─────────────────────────────────────
# CSV: filepath,bpm,loudness,duration,title,artist,album,genre
FILTERED=$(awk -F',' -v bmin="$BPM_MIN" -v bmax="$BPM_MAX" \
  'NR>1 && $2+0>=bmin && $2+0<=bmax && $2+0>0 {print}' "$CACHE_FILE")

MATCHED=$(echo "$FILTERED" | grep -c . || echo 0)
echo "  Canciones que encajan: $MATCHED"

if [[ "$MATCHED" -lt 5 ]]; then
  warn "Pocas canciones coinciden con este criterio."
  if [[ "$MODE" != "mezcla" ]]; then
    warn "Incluyendo canciones sin BPM analizado como relleno..."
    # Añadir canciones con BPM=0 (no analizadas o no detectadas)
    EXTRA=$(awk -F',' 'NR>1 && $2+0==0 {print}' "$CACHE_FILE")
    FILTERED="${FILTERED}"$'\n'"${EXTRA}"
  fi
fi

# ── Generar M3U ──────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y%m%d_%H%M')
OUT="$PLAYLIST_DIR/DJ-${LABEL}-${TIMESTAMP}.m3u"

{
  echo "#EXTM3U"
  echo "#PLAYLIST:DJ $LABEL — $(date '+%d/%m/%Y')"
  echo ""
  echo "$FILTERED" \
    | shuf \
    | head -n "$COUNT" \
    | awk -F',' -v music_dir="$MUSIC_DIR" '{
        duration = $4+0
        title    = $5
        artist   = $6
        filepath = $1
        # Ruta relativa al directorio de música (Navidrome la necesita así)
        rel = substr(filepath, length(music_dir)+2)
        printf "#EXTINF:%d,%s - %s\n%s\n", duration, artist, title, rel
      }'
} > "$OUT"

FINAL_COUNT=$(grep -c "^[^#]" "$OUT" || echo 0)

echo ""
info "Playlist generada: $(basename "$OUT")"
info "Canciones incluidas: $FINAL_COUNT"
info "Ubicación: $OUT"
echo ""
echo "  Para que aparezca en Navidrome:"
echo "  → Ve a Navidrome > ícono usuario > 'Escanear biblioteca'"
echo "  → La playlist aparecerá en la sección Playlists"
echo ""

# Notificación ntfy
[[ -n "${NTFY_TOPIC:-}" ]] && \
  curl -s -d "Nueva playlist DJ: $LABEL con $FINAL_COUNT canciones. Escanea la biblioteca en Navidrome." \
    "https://ntfy.sh/${NTFY_TOPIC}" \
    -H "Title: Axcenmusic — DJ" \
    -H "Tags: headphones" \
    &>/dev/null || true
