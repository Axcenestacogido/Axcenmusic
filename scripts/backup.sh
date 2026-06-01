#!/usr/bin/env bash
# Backup de navidrome-data/ (base de datos, playlists, valoraciones)
# Uso manual:  sudo bash scripts/backup.sh
# Automático:  cron configurado por 06-setup-extras.sh (cada día a las 3 AM)
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
    -H "Title: Axcenmusic — Backup" \
    -H "Priority: default" \
    -H "Tags: floppy_disk" \
    &>/dev/null || true
}

DATA_DIR="$REPO_DIR/navidrome-data"
BACKUP_BASE="${MUSIC_DIR:-/mnt/music}/.backups"
KEEP=7

[[ -d "$DATA_DIR" ]] || error "No existe $DATA_DIR. ¿Navidrome ha arrancado alguna vez?"

mkdir -p "$BACKUP_BASE"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_PATH="$BACKUP_BASE/navidrome-${TIMESTAMP}.tar.gz"

info "Creando backup: $BACKUP_PATH"
tar -czf "$BACKUP_PATH" -C "$REPO_DIR" navidrome-data/
SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
info "Backup completado: $SIZE"

# Retención: conservar solo los últimos $KEEP backups
COUNT=$(ls -1 "$BACKUP_BASE"/navidrome-*.tar.gz 2>/dev/null | wc -l)
if [[ "$COUNT" -gt "$KEEP" ]]; then
  EXCESS=$((COUNT - KEEP))
  info "Eliminando $EXCESS backup(s) antiguo(s)..."
  ls -1t "$BACKUP_BASE"/navidrome-*.tar.gz | tail -n "$EXCESS" | xargs rm -f
fi

info "Backups disponibles (últimos $KEEP):"
ls -lh "$BACKUP_BASE"/navidrome-*.tar.gz 2>/dev/null || true

notify "Backup completado (${SIZE}). Se conservan los últimos ${KEEP}."
