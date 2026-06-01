#!/usr/bin/env bash
# =============================================================
#  PASO 2 — Instalación de Docker y Docker Compose
#  Usa el script oficial de Docker (compatible con ARM/Pi OS)
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

PI_USER="${PI_USER:-pi}"

# ---- Docker Engine ----
if command -v docker &>/dev/null; then
  info "Docker ya está instalado: $(docker --version)"
else
  info "Instalando Docker Engine via script oficial..."
  curl -fsSL https://get.docker.com | sh

  info "Añadiendo usuario '$PI_USER' al grupo docker..."
  usermod -aG docker "$PI_USER"
  info "Nota: los cambios de grupo se aplican en la siguiente sesión SSH."
fi

# ---- Docker Compose (plugin v2) ----
if docker compose version &>/dev/null 2>&1; then
  info "Docker Compose ya está disponible: $(docker compose version)"
elif command -v docker-compose &>/dev/null; then
  info "docker-compose (v1) encontrado: $(docker-compose --version)"
  warn "Se recomienda la versión 2 (plugin). Instalando..."
  apt-get install -y -qq docker-compose-plugin || \
    pip3 install docker-compose || \
    warn "No se pudo actualizar a Compose v2, usando v1."
else
  info "Instalando Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin || {
    warn "Plugin no disponible via apt. Instalando binario standalone..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
      | grep '"tag_name"' | cut -d'"' -f4)
    ARCH=$(uname -m)
    curl -SL \
      "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    info "Docker Compose instalado: $(docker-compose --version)"
  }
fi

# ---- Habilitar Docker al arranque ----
info "Habilitando Docker para arranque automático..."
systemctl enable docker
systemctl start docker

# ---- Test rápido ----
info "Verificando instalación con imagen de prueba..."
docker run --rm hello-world | grep -q "Hello from Docker" && \
  info "Docker funciona correctamente." || \
  warn "El test de Docker falló — revisa la instalación."

info "Docker instalado y configurado."
