#!/usr/bin/env bash
# Actualiza Navidrome a la última versión disponible
# Uso: sudo bash scripts/update.sh
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
    -H "Title: Axcenmusic — Actualización" \
    -H "Priority: default" \
    -H "Tags: arrows_counterclockwise" \
    &>/dev/null || true
}

[[ $EUID -ne 0 ]] && error "Ejecutar con sudo: sudo bash scripts/update.sh"

# Versión antes de actualizar
CURRENT=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' navidrome 2>/dev/null || echo "desconocida")
info "Versión actual de Navidrome: $CURRENT"

# Backup antes de tocar nada
info "Haciendo backup previo a la actualización..."
bash "$REPO_DIR/scripts/backup.sh"

# Descargar nueva imagen
info "Descargando última imagen de Navidrome..."
cd "$REPO_DIR"
docker compose pull

# Reiniciar con la nueva imagen
info "Reiniciando Navidrome..."
docker compose up -d

# Esperar a que responda
ND_PORT="${ND_PORT:-4533}"
info "Esperando que Navidrome arranque..."
for i in {1..20}; do
  if wget -q --spider "http://localhost:${ND_PORT}/ping" 2>/dev/null; then
    NEW=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' navidrome 2>/dev/null || echo "?")
    info "Actualización completada. Versión anterior: $CURRENT → Nueva: $NEW"
    notify "Navidrome actualizado: $CURRENT → $NEW"
    exit 0
  fi
  sleep 3
done

warn "Navidrome tardó en responder tras la actualización."
warn "Comprueba los logs: docker compose -f $REPO_DIR/docker-compose.yml logs navidrome"
notify "Actualización completada pero Navidrome no respondió. Revisa los logs."
