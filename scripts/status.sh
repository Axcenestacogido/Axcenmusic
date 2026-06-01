#!/usr/bin/env bash
# Dashboard de estado de Axcenmusic
# Uso: bash scripts/status.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "  ${GREEN}✓${NC}  $*"; }
fail()  { echo -e "  ${RED}✗${NC}  $*"; }
mwarn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
field() { printf "  ${CYAN}%-22s${NC}  " "$1:"; }

clear 2>/dev/null || true
echo ""
echo -e "${BOLD}  ══════════════════════════════════════════════════"
echo    "      AXCENMUSIC — Estado del sistema"
echo -e "  ══════════════════════════════════════════════════${NC}"
echo ""

# ── Navidrome ─────────────────────────────────────────────────────
ND_PORT="${ND_PORT:-4533}"
field "Navidrome"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "navidrome"; then
  ND_VER=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' navidrome 2>/dev/null || echo "?")
  if wget -q --spider "http://localhost:${ND_PORT}/ping" 2>/dev/null; then
    echo -e "${GREEN}corriendo${NC}  (v${ND_VER}, :${ND_PORT})"
  else
    echo -e "${YELLOW}container activo pero sin respuesta${NC}"
  fi
else
  echo -e "${RED}detenido${NC}"
fi

# ── Tailscale ─────────────────────────────────────────────────────
field "Tailscale"
if command -v tailscale &>/dev/null; then
  TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
  if [[ -n "$TS_IP" ]]; then
    echo -e "${GREEN}conectado${NC}  ($TS_IP)"
  else
    echo -e "${YELLOW}instalado, no conectado${NC}"
  fi
else
  echo -e "${RED}no instalado${NC}"
fi

# ── Almacenamiento ────────────────────────────────────────────────
MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
field "Almacenamiento"
if mountpoint -q "$MUSIC_DIR" 2>/dev/null; then
  DISK=$(df -h "$MUSIC_DIR" | awk 'NR==2 {printf "%s usados / %s total (%s libre)", $3, $2, $4}')
  echo -e "${GREEN}montado${NC}  ($DISK)"
else
  echo -e "${RED}no montado${NC}  ($MUSIC_DIR)"
fi

# ── Canciones ─────────────────────────────────────────────────────
field "Canciones"
SONGS=$(find "$MUSIC_DIR" -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" -o -iname "*.opus" \) 2>/dev/null | wc -l)
echo "$SONGS archivos de audio"

# ── Letras ────────────────────────────────────────────────────────
field "Letras (.lrc)"
LRC=$(find "$MUSIC_DIR" -type f -iname "*.lrc" 2>/dev/null | wc -l)
echo "$LRC archivos"

# ── SFTP ──────────────────────────────────────────────────────────
field "SFTP (musicupload)"
if id "musicupload" &>/dev/null; then
  echo -e "${GREEN}configurado${NC}"
else
  echo -e "${RED}no configurado${NC}"
fi

# ── yt-dlp ────────────────────────────────────────────────────────
field "yt-dlp"
if command -v yt-dlp &>/dev/null; then
  YT_VER=$(yt-dlp --version 2>/dev/null || echo "?")
  echo -e "${GREEN}instalado${NC}  (v${YT_VER})"
else
  echo -e "${YELLOW}no instalado${NC}"
fi

# ── ntfy.sh ───────────────────────────────────────────────────────
field "Notificaciones (ntfy)"
if [[ -n "${NTFY_TOPIC:-}" ]]; then
  echo -e "${GREEN}activas${NC}  (topic: ${NTFY_TOPIC})"
else
  echo -e "${YELLOW}desactivadas${NC}  (añade NTFY_TOPIC a .env)"
fi

# ── Último backup ─────────────────────────────────────────────────
field "Último backup"
BACKUP_BASE="${MUSIC_DIR}/.backups"
LAST=$(ls -1t "$BACKUP_BASE"/navidrome-*.tar.gz 2>/dev/null | head -1 || echo "")
if [[ -n "$LAST" ]]; then
  BDATE=$(stat -c '%y' "$LAST" | cut -d'.' -f1)
  BSIZE=$(du -sh "$LAST" | cut -f1)
  echo -e "${GREEN}${BDATE}${NC}  (${BSIZE})"
else
  echo -e "${YELLOW}ninguno todavía${NC}"
fi

# ── Sistema ───────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Sistema${NC}"

field "Uptime"
uptime -p 2>/dev/null | sed 's/up //' || uptime | awk '{print $3,$4}' | sed 's/,//'

field "CPU temperatura"
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
  TEMP=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
  if   [[ "$TEMP" -ge 70 ]]; then echo -e "${RED}${TEMP}°C  (alta)${NC}"
  elif [[ "$TEMP" -ge 55 ]]; then echo -e "${YELLOW}${TEMP}°C${NC}"
  else echo -e "${GREEN}${TEMP}°C${NC}"; fi
else
  echo "no disponible"
fi

field "Memoria libre"
free -h | awk 'NR==2 {printf "%s libres de %s\n", $7, $2}'

# ── Comandos rápidos ──────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Comandos rápidos${NC}"
echo "    Logs:        docker compose -f $REPO_DIR/docker-compose.yml logs -f"
echo "    Actualizar:  sudo bash $REPO_DIR/scripts/update.sh"
echo "    Backup:      sudo bash $REPO_DIR/scripts/backup.sh"
echo "    Descargar:   bash $REPO_DIR/scripts/download.sh 'URL'"
echo "    Letras:      bash $REPO_DIR/scripts/lyrics.sh"
echo ""
