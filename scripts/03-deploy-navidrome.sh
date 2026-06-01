#!/usr/bin/env bash
# =============================================================
#  PASO 3 — Despliegue de Navidrome con Docker Compose
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

PI_USER="${PI_USER:-pi}"
ND_DATA_DIR="${ND_DATA_DIR:-$REPO_DIR/navidrome-data}"
MUSIC_DIR="${MUSIC_DIR:-/mnt/music}"
ND_PORT="${ND_PORT:-4533}"

# ---- Crear directorios ----
info "Creando directorios de datos..."
mkdir -p "$ND_DATA_DIR"
chown "$PI_USER:$PI_USER" "$ND_DATA_DIR"

# ---- Verificar que la música es accesible ----
if [[ ! -d "$MUSIC_DIR" ]]; then
  warn "Directorio de música '$MUSIC_DIR' no existe. Creándolo vacío."
  warn "Recuerda montar tu almacenamiento antes de que Navidrome tenga música."
  mkdir -p "$MUSIC_DIR"
fi

# ---- Seleccionar comando de Compose ----
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  error "Docker Compose no encontrado. Ejecuta primero 02-install-docker.sh"
fi

# ---- Desplegar ----
info "Descargando imagen de Navidrome (puede tardar en ARM)..."
cd "$REPO_DIR"

# Si ya estaba corriendo, hacer rolling update
if $COMPOSE_CMD ps navidrome 2>/dev/null | grep -q "Up"; then
  info "Navidrome ya está corriendo. Actualizando..."
  $COMPOSE_CMD pull navidrome
  $COMPOSE_CMD up -d navidrome
else
  info "Iniciando Navidrome..."
  $COMPOSE_CMD up -d
fi

# ---- Esperar healthcheck ----
info "Esperando que Navidrome esté listo (máx. 60s)..."
for i in $(seq 1 12); do
  if curl -sf "http://localhost:${ND_PORT}/ping" &>/dev/null; then
    info "Navidrome responde correctamente en el puerto ${ND_PORT}."
    break
  fi
  [[ $i -eq 12 ]] && { warn "Timeout esperando Navidrome. Revisa los logs:"; $COMPOSE_CMD logs navidrome; }
  sleep 5
done

# ---- Crear servicio systemd para reinicio automático ----
info "Creando servicio systemd para arranque automático..."
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"

cat > /etc/systemd/system/axcenmusic.service << EOF
[Unit]
Description=Axcenmusic - Servidor de música personal (Navidrome)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$REPO_DIR
EnvironmentFile=$REPO_DIR/.env
ExecStart=/usr/bin/bash -c 'cd $REPO_DIR && $COMPOSE_CMD up -d'
ExecStop=/usr/bin/bash -c 'cd $REPO_DIR && $COMPOSE_CMD down'
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable axcenmusic.service
info "Servicio systemd 'axcenmusic' activado para arranque automático."

# ---- Resumen ----
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo ""
info "Navidrome arrancado correctamente."
echo ""
echo "  Acceso local (misma red):  http://${LOCAL_IP}:${ND_PORT}"
echo "  Acceso Tailscale:          http://\$(tailscale ip -4):${ND_PORT}"
echo ""
echo "  En el primer acceso, crea tu cuenta de administrador."
echo "  Usuario sugerido: admin"
echo ""
warn "Guarda bien el usuario y contraseña — no hay recuperación sin acceso al fichero de datos."
