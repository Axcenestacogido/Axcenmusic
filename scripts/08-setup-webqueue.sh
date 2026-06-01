#!/usr/bin/env bash
# =============================================================
#  PASO 8 — Cola de descargas web (interfaz para descargar
#  música desde el iPhone sin necesitar SSH)
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

[[ $EUID -ne 0 ]] && { echo "Ejecutar con sudo"; exit 1; }

command -v yt-dlp &>/dev/null \
  || { warn "yt-dlp no encontrado. Ejecuta primero: sudo bash scripts/06-setup-extras.sh"; exit 1; }

WEBQUEUE_PORT="${WEBQUEUE_PORT:-8888}"
PI_USER="${PI_USER:-pi}"
SERVER_SCRIPT="$REPO_DIR/webqueue/server.py"

chmod +x "$SERVER_SCRIPT"

# ── Servicio systemd ──────────────────────────────────────────────
SERVICE_FILE="/etc/systemd/system/axcenmusic-webqueue.service"
info "Creando servicio systemd..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Axcenmusic — Cola de descargas web
Documentation=https://github.com/Axcenestacogido/Axcenmusic
After=network.target

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$REPO_DIR
ExecStart=/usr/bin/python3 $SERVER_SCRIPT
EnvironmentFile=$REPO_DIR/.env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now axcenmusic-webqueue
sleep 2

if systemctl is-active --quiet axcenmusic-webqueue; then
  info "Servicio axcenmusic-webqueue activo."
else
  warn "El servicio no arrancó. Comprueba:"
  warn "  sudo journalctl -u axcenmusic-webqueue -n 30"
fi

# ── Firewall: permitir el puerto en Tailscale ─────────────────────
# (No hace falta abrir en el firewall externo ya que solo accedemos via Tailscale)

# ── URL de acceso ─────────────────────────────────────────────────
TS_IP=$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print $1}')
TS_HOSTNAME="${TAILSCALE_HOSTNAME:-pimusic}"

echo ""
info "Cola de descargas disponible:"
echo ""
echo "   http://${TS_HOSTNAME}:${WEBQUEUE_PORT}"
echo "   http://${TS_IP}:${WEBQUEUE_PORT}"
echo ""
echo "   (Solo accesible desde tu red Tailscale)"
echo ""
echo "  Comandos de gestión:"
echo "    Estado:    sudo systemctl status axcenmusic-webqueue"
echo "    Logs:      sudo journalctl -u axcenmusic-webqueue -f"
echo "    Reiniciar: sudo systemctl restart axcenmusic-webqueue"
echo ""
