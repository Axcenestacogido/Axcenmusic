#!/usr/bin/env bash
# =============================================================
#  PASO 9 — Tailscale Funnel para Navidrome
#  Expone Navidrome en una URL pública HTTPS sin abrir puertos
#  en el router y sin necesitar Tailscale activo en el iPhone.
#
#  URL resultante: https://pimusic.<tailnet>.ts.net
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}▶ $*${NC}"; }

[[ $EUID -ne 0 ]] && error "Ejecutar con sudo: sudo bash scripts/09-setup-funnel.sh"

ND_PORT="${ND_PORT:-4533}"
WEBQUEUE_PORT="${WEBQUEUE_PORT:-8888}"
HOMEPAGE_PORT="${HOMEPAGE_PORT:-7575}"

# ── 1. Verificar Tailscale ────────────────────────────────────────
step "Verificando Tailscale"
command -v tailscale &>/dev/null || error "Tailscale no está instalado. Ejecuta primero 04-install-tailscale.sh"

TS_STATUS=$(tailscale status --json 2>/dev/null || echo '{}')
TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
[[ -z "$TS_IP" ]] && error "Tailscale no está conectado. Ejecuta: tailscale up"
info "Tailscale conectado ($TS_IP)"

TS_VER=$(tailscale version | head -1 | grep -oP '[\d]+\.[\d]+' | head -1 || echo "0.0")
TS_MAJOR=$(echo "$TS_VER" | cut -d. -f1)
TS_MINOR=$(echo "$TS_VER" | cut -d. -f2)
if [[ "$TS_MAJOR" -lt 1 ]] || { [[ "$TS_MAJOR" -eq 1 ]] && [[ "$TS_MINOR" -lt 40 ]]; }; then
  warn "Tailscale v${TS_VER} puede ser demasiado antiguo. Se recomienda v1.40+."
  warn "Actualiza con: curl -fsSL https://tailscale.com/install.sh | sh"
fi
info "Versión Tailscale: $(tailscale version | head -1)"

# ── 2. Requisitos en el panel de Tailscale ────────────────────────
step "Requisitos previos en el panel de Tailscale"
echo ""
echo "  Antes de continuar, verifica en https://login.tailscale.com/admin/dns :"
echo ""
echo "    1. MagicDNS          → ACTIVADO"
echo "    2. HTTPS Certificates → ACTIVADO"
echo ""
echo "  Y en https://login.tailscale.com/admin/acls añade si no está:"
echo '    "nodeAttrs": [{"target": ["*"], "attr": ["funnel"]}]'
echo ""
read -rp "  ¿Ya están activados? (s/N): " CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && { warn "Actívalos primero y vuelve a ejecutar este script."; exit 0; }

# ── 3. Activar Funnel ─────────────────────────────────────────────
step "Activando Tailscale Funnel"

# Quitar configuración previa si existe
tailscale serve reset 2>/dev/null || true

# Exponer Navidrome via Funnel (puerto público 443)
tailscale funnel --bg --https=443 "${ND_PORT}" \
  && info "Navidrome publicado en el puerto 443." \
  || error "No se pudo activar el Funnel. Asegúrate de haber habilitado 'funnel' en el ACL de Tailscale."

# Exponer WebQueue via Funnel (puerto público 8443)
tailscale funnel --bg --https=8443 "${WEBQUEUE_PORT}" \
  && info "WebQueue publicado en el puerto 8443." \
  || warn "No se pudo publicar WebQueue en el puerto 8443."

# Exponer el hub (homepage) via Funnel (puerto público 10000)
tailscale funnel --bg --https=10000 "${HOMEPAGE_PORT}" \
  && info "Panel de inicio publicado en el puerto 10000." \
  || warn "No se pudo publicar el panel de inicio en el puerto 10000."

# ── 4. Obtener URL pública ────────────────────────────────────────
step "Obteniendo URL pública"
sleep 2
PUBLIC_URL=$(tailscale funnel status 2>/dev/null | grep -oP 'https://[^\s]+' | head -1 || echo "")

if [[ -z "$PUBLIC_URL" ]]; then
  TS_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('Self',{}).get('DNSName','').rstrip('.'))
" 2>/dev/null || echo "")
  [[ -n "$TS_HOSTNAME" ]] && PUBLIC_URL="https://${TS_HOSTNAME}"
fi

# ── 5. Servicio systemd para persistencia ────────────────────────
step "Creando servicio systemd (arranque automático)"
cat > /etc/systemd/system/axcenmusic-funnel.service <<EOF
[Unit]
Description=Axcenmusic — Tailscale Funnel (Navidrome público)
After=tailscaled.service network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/tailscale funnel --bg --https=443 ${ND_PORT}
ExecStart=/usr/bin/tailscale funnel --bg --https=8443 ${WEBQUEUE_PORT}
ExecStart=/usr/bin/tailscale funnel --bg --https=10000 ${HOMEPAGE_PORT}
ExecStop=/usr/bin/tailscale funnel --bg --https=443 --off ${ND_PORT}
ExecStop=/usr/bin/tailscale funnel --bg --https=8443 --off ${WEBQUEUE_PORT}
ExecStop=/usr/bin/tailscale funnel --bg --https=10000 --off ${HOMEPAGE_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable axcenmusic-funnel.service
systemctl start  axcenmusic-funnel.service
info "Servicio axcenmusic-funnel habilitado."

# ── 6. Resumen ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Tailscale Funnel configurado correctamente${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
if [[ -n "$PUBLIC_URL" ]]; then
  HUB_BASE="${PUBLIC_URL%%:*}"
  echo -e "  URL pública de Navidrome:"
  echo -e "  ${CYAN}${PUBLIC_URL}${NC}"
  echo ""
  echo -e "  Panel con acceso a todas las apps (añádelo a la pantalla de inicio):"
  echo -e "  ${CYAN}${HUB_BASE}:10000${NC}"
  echo ""
  echo "  Configura NaviBeat / Amperfy con la URL de Navidrome."
  echo "  No hace falta tener Tailscale activo en el iPhone."
else
  echo "  No se pudo detectar la URL automáticamente."
  echo "  Ejecútalo para verla:"
  echo "    tailscale funnel status"
fi
echo ""
echo "  Gestión del Funnel:"
echo "    Ver estado:    tailscale funnel status"
echo "    Desactivar:    sudo systemctl stop axcenmusic-funnel"
echo "    Reactivar:     sudo systemctl start axcenmusic-funnel"
echo ""
warn "La URL es pública. Asegúrate de tener contraseña en tu cuenta de Navidrome."
