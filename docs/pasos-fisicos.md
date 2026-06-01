# Pasos que requieren presencia física

Esta guía separa con claridad qué necesitas hacer delante de la Pi de lo que puedes preparar de antemano.

---

## Antes de tener acceso físico (ya hecho)

- [x] Clonar este repositorio
- [x] Revisar `.env.example`
- [x] Tener cuenta de Tailscale creada (gratuita)
- [x] Generar auth key de Tailscale en [tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
- [x] Decidir estructura de carpetas de música

---

## Fase 1 — Con acceso físico a la Pi (una sola vez)

### 1.1 — Flash de la tarjeta SD

**Herramienta:** [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

**Imagen a usar:** `Raspberry Pi OS Lite (64-bit)` — sin escritorio, más ligero.

**Configuración avanzada en Imager** (engranaje ⚙️ antes de escribir):
- [x] Hostname: `pimusic` (o el que pusiste en `TAILSCALE_HOSTNAME`)
- [x] Enable SSH: **sí**, con contraseña o clave pública
- [x] Usuario: `pi` / contraseña que elijas
- [x] Wi-Fi: configúralo aquí si la Pi no irá por cable Ethernet
- [x] Locale: `Europe/Madrid`, teclado `es`

> Si la Pi va conectada por cable Ethernet puedes omitir la configuración Wi-Fi.

### 1.2 — Primera encendida

1. Inserta la microSD en la Pi.
2. Conecta el cable Ethernet (recomendado para la instalación).
3. Conecta el cable de alimentación.
4. Espera ~60 segundos a que arranque.

### 1.3 — Primer SSH

Desde tu ordenador en la misma red:

```bash
# Descubrir la IP de la Pi (elige uno):
ping pimusic.local          # mDNS, funciona si Avahi está activo
nmap -sn 192.168.1.0/24 | grep -i raspberry   # escaneo de red local

# Conectar por SSH:
ssh pi@pimusic.local
# o
ssh pi@<IP-de-la-Pi>
```

### 1.4 — Clonar el repositorio en la Pi

```bash
# Dentro de la Pi:
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/axcenestacogido/axcenmusic.git ~/axcenmusic
cd ~/axcenmusic
```

### 1.5 — Configurar variables de entorno

```bash
cp .env.example .env
nano .env
```

**Campos obligatorios a rellenar:**

| Variable | Cómo obtenerla |
|---|---|
| `STORAGE_UUID` | `sudo blkid` tras conectar el HDD/microSD |
| `STORAGE_FSTYPE` | Ver salida de `blkid` (ext4, exfat, ntfs...) |
| `TAILSCALE_AUTH_KEY` | [tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) |

### 1.6 — Identificar el almacenamiento de música

```bash
# Conecta tu HDD externo o microSD adicional, luego:
lsblk
sudo blkid

# Ejemplo de salida:
# /dev/sda1: UUID="a1b2c3d4-..." TYPE="ext4"
# Copia ese UUID al .env: STORAGE_UUID=a1b2c3d4-...
```

> Si el disco es nuevo y no tiene sistema de ficheros:
> ```bash
> sudo mkfs.ext4 /dev/sda1   # formatea en ext4 (borra todo)
> sudo blkid /dev/sda1        # obtén el UUID tras formatear
> ```

### 1.7 — Ejecutar el script de instalación

```bash
cd ~/axcenmusic
sudo bash scripts/00-bootstrap.sh
```

Duración estimada: **10–20 minutos** (dependiendo de la conexión).

---

## Fase 2 — Configuración inicial (se puede hacer desde el iPhone)

Una vez instalado Tailscale, todo lo demás puede hacerse en remoto.

### 2.1 — Instalar Tailscale en el iPhone

1. App Store → buscar `Tailscale` → instalar
2. Abrir → iniciar sesión con la misma cuenta
3. La Pi aparece como `pimusic` en la lista de dispositivos

### 2.2 — Primera visita a Navidrome

Con Tailscale activo en el iPhone:

1. Safari → `http://pimusic:4533` (o la IP Tailscale de la Pi)
2. Se pedirá crear el primer usuario administrador
3. Elige usuario/contraseña y guárdalos bien

### 2.3 — Configurar Amperfy (o NaviBeat) en el iPhone

| Campo | Valor |
|---|---|
| Tipo de servidor | Subsonic / OpenSubsonic |
| URL del servidor | `http://pimusic:4533` |
| Usuario | el que creaste en Navidrome |
| Contraseña | la que creaste en Navidrome |

> Cambiar en el futuro de Amperfy a NaviBeat (o cualquier cliente OpenSubsonic):
> solo cambia la app. La URL, usuario y contraseña del servidor son idénticos.

---

## Resumen visual de fases

```
AHORA (sin Pi)          CON ACCESO FÍSICO        EN REMOTO
──────────────          ─────────────────        ─────────
Flash SD           →    1ª encendida         →   Tailscale en iPhone
Configurar .env    →    1er SSH              →   1ª visita Navidrome
Generar auth key   →    git clone            →   Configurar Amperfy
                        00-bootstrap.sh      →   Subir música (SFTP)
```
