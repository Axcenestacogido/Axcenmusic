#!/usr/bin/env bash
# =============================================================
#  PASO 10 — Soulseek (slskd) + Lidarr + Prowlarr + editor de tags
#  Opcional: gestión avanzada de biblioteca y descarga P2P.
#
#  Aviso: en una Raspberry Pi 3 (1 GB RAM) esto añade varios
#  contenedores más sobre Navidrome. Vigila el consumo con
#  'docker stats' y considera activar swap si notas lentitud.
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Ejecutar con sudo: sudo bash scripts/10-setup-media-stack.sh"

MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
PI_USER="${PI_USER:-pi}"
ENV_FILE="$REPO_DIR/.env"

# ── Añadir variables nuevas al .env si faltan ────────────────────
add_env_default() {
  local key="$1" default="$2"
  if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    echo "${key}=${default}" >> "$ENV_FILE"
    info "Añadido ${key}=${default} a .env"
  fi
}
add_env_default "MUSIC_TAG_PORT" "6677"
add_env_default "LIDARR_PORT"    "8686"
add_env_default "PROWLARR_PORT" "9696"
add_env_default "SLSKD_PORT"    "5030"
add_env_default "DOWNLOADS_DIR" "${MUSIC_DIR}/downloads"
add_env_default "TZ"            "Europe/Madrid"

set -a; source "$ENV_FILE"; set +a

# ── Directorios de descarga ───────────────────────────────────────
mkdir -p "${DOWNLOADS_DIR:-$MUSIC_DIR/downloads}" "$MUSIC_DIR/soulseek"
chown "$PI_USER:$PI_USER" "${DOWNLOADS_DIR:-$MUSIC_DIR/downloads}" "$MUSIC_DIR/soulseek" 2>/dev/null || true

# ── Seleccionar comando de Compose ────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  error "Docker Compose no encontrado. Ejecuta primero 02-install-docker.sh"
fi

# ── Aviso de RAM en Pi 3 ───────────────────────────────────────────
TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "$TOTAL_MEM_MB" -gt 0 && "$TOTAL_MEM_MB" -lt 1500 ]]; then
  warn "Detectados ${TOTAL_MEM_MB} MB de RAM. Soulseek + Lidarr + Prowlarr + editor"
  warn "de tags junto a Navidrome pueden llegar a ir justos en una Pi 3."
  warn "Vigila el consumo con: docker stats"
fi

cd "$REPO_DIR"

info "Descargando e iniciando editor de tags, Lidarr, Prowlarr y Soulseek..."
$COMPOSE_CMD --profile tags --profile lidarr --profile soulseek pull
$COMPOSE_CMD --profile tags --profile lidarr --profile soulseek up -d

info "Esperando que los servicios arranquen (30s)..."
sleep 30

# ── Resumen ────────────────────────────────────────────────────────
TS_HOSTNAME="${TAILSCALE_HOSTNAME:-pimusic}"
TS_IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Soulseek, Lidarr, Prowlarr y editor de tags listos${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  Todos accesibles solo dentro de tu red Tailscale (no públicos):"
echo ""
echo "  Editor de tags:  http://${TS_HOSTNAME}:${MUSIC_TAG_PORT}"
echo "  Lidarr:          http://${TS_HOSTNAME}:${LIDARR_PORT}"
echo "  Prowlarr:        http://${TS_HOSTNAME}:${PROWLARR_PORT}"
echo "  Soulseek (slskd):http://${TS_HOSTNAME}:${SLSKD_PORT}"
echo ""
echo "  (o sustituye ${TS_HOSTNAME} por ${TS_IP})"
echo ""
echo "  ── Editor de tags ──────────────────────────────────────"
echo "  1. Abre la URL, selecciona varios archivos con Ctrl+clic"
echo "  2. Edita artista/álbum/año/carátula en masa y guarda"
echo "  3. En Navidrome: Biblioteca → Escanear ahora"
echo ""
echo "  ── Soulseek (slskd) ────────────────────────────────────"
echo "  1. Abre la URL, crea una cuenta gratis en slsknet.org"
echo "  2. Settings → Soulseek → introduce usuario y contraseña"
echo "  3. Busca música → descarga → aparece en /music/soulseek"
echo ""
echo "  ── Prowlarr + Lidarr ───────────────────────────────────"
echo "  1. En Prowlarr: Settings → Apps → + → Lidarr"
echo "     URL: http://axcen-lidarr:8686  (API key en Lidarr → Settings → General)"
echo "  2. En Prowlarr: Indexers → + → añade los que quieras"
echo "  3. Sync All → Lidarr los hereda automáticamente"
echo "  4. En Lidarr: Settings → Media Management → Root Folders → añade /music"
echo "  5. Settings → Download Clients → añade tu cliente de descargas"
echo "  6. Artist → Add New Artist → Lidarr descargará sus álbumes automáticamente"
echo ""
warn "Estos servicios requieren Tailscale activo en el dispositivo — no se exponen"
warn "por Funnel al ser paneles de administración, no pensados para acceso público."
echo ""
