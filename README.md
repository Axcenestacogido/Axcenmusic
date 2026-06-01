# Axcenmusic — Servidor de música personal

Raspberry Pi 3 · Navidrome · Tailscale · OpenSubsonic

Tu propia colección de música disponible desde cualquier lugar, accesible desde iPhone como un Spotify privado y sin suscripciones.

---

## Arquitectura

```
iPhone (Amperfy / NaviBeat)
        │
        │  OpenSubsonic API
        │  (HTTP sobre Tailscale VPN)
        ▼
┌─────────────────────────────┐
│   Raspberry Pi 3            │
│                             │
│   ┌─────────────────────┐   │
│   │  Navidrome (Docker) │   │
│   │  puerto 4533        │   │
│   └──────────┬──────────┘   │
│              │ /music (ro)  │
│   ┌──────────▼──────────┐   │
│   │  HDD externo /      │   │
│   │  microSD adicional  │   │
│   │  montado en         │   │
│   │  /mnt/music         │   │
│   └─────────────────────┘   │
│                             │
│   Tailscale                 │
│   SSH + SFTP (puerto 22)    │
└─────────────────────────────┘
        ▲
        │  SFTP (subir música)
        │  Tailscale VPN
        │
iPhone (FE File Explorer / Owlfiles)
```

**Por qué este stack:**
- **Navidrome** es el servidor más ligero con soporte OpenSubsonic — funciona bien en Pi 3 con 1 GB de RAM.
- **Tailscale** proporciona acceso remoto seguro sin abrir puertos en el router.
- **OpenSubsonic** es el protocolo estándar de facto: cambiar de Amperfy a NaviBeat (u otro cliente) solo requiere cambiar la app en el iPhone. El servidor no se toca.
- **Docker** facilita actualizaciones y aisla Navidrome del sistema.

---

## Estructura del repositorio

```
axcenmusic/
├── .env.example              # Plantilla de configuración (copia a .env)
├── .gitignore
├── docker-compose.yml        # Stack Docker de Navidrome
├── scripts/
│   ├── 00-bootstrap.sh       # Script maestro — ejecuta todo en orden
│   ├── 01-system-setup.sh    # Actualiza el sistema, monta almacenamiento
│   ├── 02-install-docker.sh  # Instala Docker y Docker Compose
│   ├── 03-deploy-navidrome.sh# Despliega Navidrome + servicio systemd
│   ├── 04-install-tailscale.sh # Instala y configura Tailscale
│   └── 05-setup-sftp.sh      # Configura usuario SFTP para subida desde iPhone
└── docs/
    ├── pasos-fisicos.md      # Qué hacer delante de la Pi (flash, SSH, etc.)
    ├── subir-musica-iphone.md# Cómo subir música desde iPhone por SFTP
    └── checklist.md          # Verificación completa paso a paso
```

---

## Inicio rápido

### Paso 0 — Preparar ahora (sin la Pi)

```bash
# 1. Clonar este repositorio
git clone https://github.com/axcenestacogido/axcenmusic.git
cd axcenmusic

# 2. Crear el fichero de configuración
cp .env.example .env

# 3. Rellenar: TAILSCALE_AUTH_KEY, STORAGE_UUID, STORAGE_FSTYPE
#    (STORAGE_UUID lo obtendrás con 'blkid' cuando tengas la Pi)
nano .env
```

### Paso 1 — Flash de la microSD

Ver **[docs/pasos-fisicos.md](docs/pasos-fisicos.md)** → sección 1.1.

Usa Raspberry Pi Imager con **Raspberry Pi OS Lite (64-bit)** y activa SSH.

### Paso 2 — Primera conexión SSH a la Pi

```bash
ssh pi@pimusic.local
```

### Paso 3 — Clonar el repositorio en la Pi

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/axcenestacogido/axcenmusic.git ~/axcenmusic
cd ~/axcenmusic
cp .env.example .env
nano .env   # rellena los valores
```

### Paso 4 — Ejecutar el instalador

```bash
sudo bash scripts/00-bootstrap.sh
```

Duración: **10–20 minutos**.

### Paso 5 — Verificar

Sigue el **[checklist de verificación](docs/checklist.md)**.

---

## Cambiar de cliente iOS en el futuro

El servidor no requiere ningún cambio. En la nueva app:

| Campo | Valor |
|---|---|
| Tipo de servidor | Subsonic / OpenSubsonic |
| URL | `http://pimusic:4533` |
| Usuario | el que creaste en Navidrome |
| Contraseña | la que creaste en Navidrome |

Clientes compatibles: Amperfy, NaviBeat, Substreamer, Symfonium, play:Sub, Sonixd, y cualquier app que soporte el protocolo Subsonic/OpenSubsonic.

---

## Subir música desde iPhone

Ver **[docs/subir-musica-iphone.md](docs/subir-musica-iphone.md)**.

Resumen: SFTP con FE File Explorer → host `pimusic` → usuario `musicupload` → carpeta `/music`.

---

## Mantenimiento

```bash
# Actualizar Navidrome
cd ~/axcenmusic
docker compose pull && docker compose up -d

# Ver logs
docker compose logs -f navidrome

# Reiniciar todo
sudo systemctl restart axcenmusic
```

---

## Requisitos

- Raspberry Pi 3 (o superior) con Raspberry Pi OS Lite 64-bit
- microSD ≥ 8 GB para el sistema operativo
- Almacenamiento para música: HDD externo USB o microSD adicional
- Conexión a internet (durante la instalación y para Tailscale)
- Cuenta gratuita en [tailscale.com](https://tailscale.com)
