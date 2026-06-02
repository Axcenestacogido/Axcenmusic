#!/usr/bin/env bash
# Instala o actualiza el plugin de letras para Navidrome (nd-lyrics)
# Fuente: https://github.com/J0R6IT0/navidrome-lyrics-plugin
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="$REPO_DIR/plugins"
VERSION="${1:-v6.1.3}"
URL="https://github.com/J0R6IT0/navidrome-lyrics-plugin/releases/download/${VERSION}/nd-lyrics.ndp"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

mkdir -p "$PLUGINS_DIR"

info "Descargando nd-lyrics ${VERSION}…"
curl -fsSL -o "$PLUGINS_DIR/nd-lyrics.ndp" "$URL"
info "Guardado en $PLUGINS_DIR/nd-lyrics.ndp ($(du -sh "$PLUGINS_DIR/nd-lyrics.ndp" | cut -f1))"

info "Reiniciando Navidrome para cargar el plugin…"
cd "$REPO_DIR"
docker compose restart navidrome

echo ""
info "Plugin instalado. Pasos finales:"
echo "  1. Abre Navidrome → tu usuario → Personal"
echo "  2. Activa el plugin 'nd-lyrics' en la sección Plugins"
echo "  3. Guarda los cambios"
echo ""
warn "Navidrome debe ser v0.61.2 o superior para soportar plugins."
