#!/usr/bin/env bash
# =============================================================
#  PASO 4 — Instalación y configuración de Tailscale
#  Crea una red privada virtual para acceder a la Pi desde
#  cualquier lugar sin exponer puertos al internet público.
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

HOSTNAME_TARGET="${TAILSCALE_HOSTNAME:-pimusic}"

# ---- Instalar Tailscale ----
if command -v tailscale &>/dev/null; then
  info "Tailscale ya está instalado: $(tailscale version)"
else
  info "Instalando Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# ---- Habilitar IP forwarding (necesario para Tailscale) ----
info "Habilitando IP forwarding..."
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

# ---- Activar servicio ----
systemctl enable --now tailscaled

# ---- Autenticar ----
TAILSCALE_STATUS=$(tailscale status 2>&1 || true)

if echo "$TAILSCALE_STATUS" | grep -q "100\." 2>/dev/null; then
  info "Tailscale ya está autenticado."
  tailscale status
else
  if [[ -z "${TAILSCALE_AUTH_KEY:-}" || "$TAILSCALE_AUTH_KEY" == "tskey-auth-RELLENAR" ]]; then
    warn "No hay TAILSCALE_AUTH_KEY en .env."
    warn "Opciones para autenticar:"
    echo ""
    echo "  Opción A — Autenticación interactiva (requiere navegador):"
    echo "    sudo tailscale up --hostname=$HOSTNAME_TARGET"
    echo "    (abre la URL que aparece en un navegador y aprueba el dispositivo)"
    echo ""
    echo "  Opción B — Con auth key (sin navegador, recomendado para servidores):"
    echo "    1. Ve a https://login.tailscale.com/admin/settings/keys"
    echo "    2. Crea una auth key (reusable: no, expiry: 90 días, tag: opcional)"
    echo "    3. Añádela a .env: TAILSCALE_AUTH_KEY=tskey-auth-XXXXX"
    echo "    4. Ejecuta: sudo tailscale up --authkey=\$TAILSCALE_AUTH_KEY --hostname=$HOSTNAME_TARGET"
    echo ""
    warn "Tailscale instalado pero pendiente de autenticar."
  else
    info "Autenticando con auth key..."
    tailscale up \
      --authkey="${TAILSCALE_AUTH_KEY}" \
      --hostname="${HOSTNAME_TARGET}" \
      --accept-dns=true

    info "Tailscale autenticado. IP asignada:"
    tailscale ip -4
  fi
fi

# ---- Configurar Tailscale para arranque automático ----
systemctl enable tailscaled
info "Tailscale configurado para arranque automático."

# ---- Mostrar IP Tailscale ----
echo ""
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "(pendiente de autenticación)")
info "IP Tailscale de esta Pi: $TAILSCALE_IP"
echo ""
echo "  En el iPhone:"
echo "  1. Instala la app Tailscale desde App Store"
echo "  2. Inicia sesión con la misma cuenta"
echo "  3. La Pi aparecerá como '$HOSTNAME_TARGET' en tu red Tailscale"
echo "  4. Navidrome: http://${TAILSCALE_IP}:${ND_PORT:-4533}  (o http://${HOSTNAME_TARGET}:${ND_PORT:-4533})"
echo ""
