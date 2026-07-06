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
├── install.sh                 # Instalador interactivo (recomendado) — clona, pregunta y ejecuta todo
├── .env.example                # Plantilla de configuración (copia a .env)
├── .gitignore
├── docker-compose.yml          # Stack Docker (Navidrome + panel de inicio)
├── scripts/
│   ├── 00-bootstrap.sh         # Alternativa sin wizard — usa el .env que ya hayas rellenado
│   ├── 01-system-setup.sh      # Actualiza el sistema, monta almacenamiento
│   ├── 02-install-docker.sh    # Instala Docker y Docker Compose
│   ├── 03-deploy-navidrome.sh  # Despliega Navidrome + servicio systemd
│   ├── 04-install-tailscale.sh # Instala y configura Tailscale
│   ├── 05-setup-sftp.sh        # Configura usuario SFTP para subida desde iPhone
│   ├── 06-setup-extras.sh      # yt-dlp, ffmpeg, backup diario, notificaciones ntfy.sh
│   ├── 07-setup-beets.sh       # Etiquetado automático (Beets) + análisis de BPM
│   ├── 08-setup-webqueue.sh    # Cola de descargas web (subir música sin SSH)
│   ├── 09-setup-funnel.sh      # Opcional — expone el stack en una URL HTTPS pública
│   └── 10-setup-media-stack.sh # Opcional — Soulseek, Lidarr, Prowlarr y editor de tags
└── docs/
    ├── pasos-fisicos.md      # Qué hacer delante de la Pi (flash, SSH, etc.)
    ├── subir-musica-iphone.md# Cómo subir música desde iPhone por SFTP
    └── checklist.md          # Verificación completa paso a paso
```

---

## Inicio rápido

### Paso 1 — Flash de la microSD

Ver **[docs/pasos-fisicos.md](docs/pasos-fisicos.md)** → sección 1.1.

Usa Raspberry Pi Imager con **Raspberry Pi OS Lite (64-bit)** y activa SSH.

### Paso 2 — Primera conexión SSH a la Pi

```bash
ssh pi@pimusic.local
```

### Paso 3 — Ejecutar el instalador

La forma más rápida: un único comando que clona el repositorio y lanza
un asistente interactivo (pregunta por Tailscale, almacenamiento,
contraseña SFTP, puertos, etc. y genera el `.env` por ti).

```bash
curl -fsSL https://raw.githubusercontent.com/Axcenestacogido/Axcenmusic/main/install.sh | sudo bash
```

Al final del asistente puedes elegir activar **Tailscale Funnel**, que
publica Navidrome, la cola de descargas y el panel de inicio en una URL
HTTPS pública (sin necesitar la app Tailscale en el iPhone). Requiere
tener MagicDNS y "HTTPS Certificates" activados en tu cuenta Tailscale;
el propio instalador te lo explica antes de activarlo. Si prefieres
configurarlo más tarde, puedes ejecutarlo en cualquier momento con:

```bash
sudo bash scripts/09-setup-funnel.sh
```

También puedes activar **Soulseek (slskd), Lidarr, Prowlarr y un editor
de tags en masa** — gestión avanzada de biblioteca, todo accesible solo
dentro de tu red Tailscale. En una Raspberry Pi 3 (1 GB RAM) suman
varios contenedores más sobre Navidrome, así que en Pi 3 vigila el
consumo con `docker stats`; en Pi 4/5 no debería haber problema.
Se configura durante el wizard o, más tarde, con:

```bash
sudo bash scripts/10-setup-media-stack.sh
```

Duración total: **10–20 minutos** (más si activas los extras anteriores).

<details>
<summary>Alternativa: clonar primero y configurar el <code>.env</code> a mano</summary>

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/axcenestacogido/axcenmusic.git ~/axcenmusic
cd ~/axcenmusic
cp .env.example .env
nano .env                       # rellena TAILSCALE_AUTH_KEY, STORAGE_UUID, etc.
sudo bash scripts/00-bootstrap.sh
```

`00-bootstrap.sh` ejecuta el mismo stack completo (sistema, Docker,
Navidrome, Tailscale, SFTP, extras, Beets, cola de descargas) pero sin
el asistente interactivo — útil si prefieres revisar y editar el `.env`
tú mismo antes de instalar, o para reinstalar con una configuración ya
guardada.

</details>

### Paso 4 — Verificar

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
