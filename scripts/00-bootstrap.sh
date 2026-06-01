#!/usr/bin/env bash
# =============================================================
#  AXCENMUSIC — Script maestro de instalación
#  Ejecutar con: sudo bash scripts/00-bootstrap.sh
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"

# ---- Colores ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- Comprobaciones previas ----
[[ $EUID -ne 0 ]] && error "Ejecutar con sudo: sudo bash scripts/00-bootstrap.sh"
[[ ! -f "$REPO_DIR/.env" ]] && error "Falta el fichero .env. Crea uno primero:\n  cp .env.example .env && nano .env"

set -a; source "$REPO_DIR/.env"; set +a

echo ""
echo "=================================================="
echo "   AXCENMUSIC — Servidor de música personal"
echo "   Raspberry Pi 3 + Navidrome + Tailscale"
echo "=================================================="
echo ""
warn "Este script instala y configura todo el stack."
warn "Duración estimada: 10-20 minutos según velocidad de red."
echo ""
read -r -p "¿Continuar? [s/N] " resp
[[ "${resp,,}" != "s" ]] && { info "Cancelado."; exit 0; }

STEP=0
run_step() {
  local n=$1; local label=$2; local script=$3
  STEP=$((STEP+1))
  echo ""
  echo "──────────────────────────────────────────────────"
  info "Paso $STEP: $label"
  echo "──────────────────────────────────────────────────"
  bash "$SCRIPTS_DIR/$script"
}

run_step 1 "Preparación del sistema"        "01-system-setup.sh"
run_step 2 "Instalación de Docker"          "02-install-docker.sh"
run_step 3 "Despliegue de Navidrome"        "03-deploy-navidrome.sh"
run_step 4 "Configuración de Tailscale"     "04-install-tailscale.sh"
run_step 5 "Configuración de SFTP"          "05-setup-sftp.sh"

echo ""
echo "=================================================="
echo -e "${GREEN}   Instalación completada correctamente${NC}"
echo "=================================================="
echo ""
info "Próximos pasos:"
echo "  1. Tailscale: abre la app en el iPhone y verifica que 'pimusic' aparece."
echo "  2. Navidrome: abre http://pimusic:4533 desde Tailscale y crea tu cuenta admin."
echo "  3. Configura Amperfy/NaviBeat con la IP Tailscale de la Pi y puerto 4533."
echo "  4. Consulta docs/checklist.md para la verificación completa."
echo ""
