# Checklist de verificación — Axcenmusic

Usa esta lista el día que tengas acceso físico a la Pi y después de ejecutar el bootstrap.

---

## Fase 0 — Antes del primer encendido

- [ ] Imagen de Raspberry Pi OS Lite (64-bit) flasheada en la microSD
- [ ] SSH habilitado en Raspberry Pi Imager (o con fichero `ssh` en `/boot`)
- [ ] Hostname configurado en Imager: `pimusic`
- [ ] Wi-Fi configurado (si no usa cable)
- [ ] Usuario `pi` con contraseña conocida
- [ ] Archivo `.env` relleno con todos los valores (copia local)
- [ ] Auth key de Tailscale generada y copiada en `.env`

---

## Fase 1 — Primera conexión SSH

```bash
ssh pi@pimusic.local
```

- [ ] SSH responde correctamente
- [ ] `hostname` devuelve `pimusic`
- [ ] Internet accesible desde la Pi: `ping -c 3 8.8.8.8`
- [ ] DNS funciona: `ping -c 3 google.com`
- [ ] Almacenamiento de música conectado: `lsblk` muestra el dispositivo

---

## Fase 2 — Tras ejecutar `00-bootstrap.sh`

### Docker

```bash
docker --version          # Docker 24.x o superior
docker compose version    # Docker Compose v2.x
docker ps                 # debe mostrar el contenedor 'navidrome' como Up
docker stats --no-stream  # consumo de recursos (Pi 3: ~150MB RAM para Navidrome)
```

- [ ] Docker instalado y corriendo
- [ ] Usuario `pi` en el grupo `docker`: `groups pi | grep docker`
- [ ] Contenedor `navidrome` en estado `Up (healthy)`

### Almacenamiento

```bash
df -h /mnt/music          # debe mostrar el disco montado
ls /mnt/music             # debe listar el contenido (o estar vacío si es nuevo)
```

- [ ] `/mnt/music` está montado
- [ ] Entrada en `/etc/fstab`: `cat /etc/fstab | grep music`
- [ ] Montaje automático al reiniciar: `sudo reboot` → SSH de nuevo → `mountpoint /mnt/music`

### Navidrome

```bash
curl -sf http://localhost:4533/ping && echo "OK"
# Respuesta esperada: OK
```

- [ ] Navidrome responde en el puerto 4533
- [ ] Primer acceso web: `http://pimusic.local:4533` → pantalla de creación de admin
- [ ] Cuenta de administrador creada (usuario y contraseña guardados)
- [ ] Biblioteca escaneada (aunque esté vacía si no hay música aún)

### Servicio systemd

```bash
systemctl status axcenmusic    # debe aparecer como active (exited) o active (running)
systemctl status docker        # debe aparecer como active (running)
```

- [ ] Servicio `axcenmusic` habilitado: `systemctl is-enabled axcenmusic`
- [ ] Prueba de reinicio automático:
  ```bash
  sudo systemctl stop axcenmusic
  sudo systemctl start axcenmusic
  docker ps | grep navidrome   # debe volver a aparecer
  ```

---

## Fase 3 — Tailscale

```bash
tailscale status       # debe mostrar la Pi como "online"
tailscale ip -4        # IP en la red Tailscale (100.x.x.x)
```

- [ ] Tailscale instalado y autenticado
- [ ] La Pi aparece como `pimusic` en [tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
- [ ] Tailscale habilitado al arranque: `systemctl is-enabled tailscaled`

**Desde el iPhone (con Tailscale activo):**

- [ ] `http://pimusic:4533` carga Navidrome en Safari
- [ ] No se necesita estar en la misma red Wi-Fi

---

## Fase 4 — SFTP

**Desde el iPhone con FE File Explorer / Owlfiles:**

```
Host:     pimusic  (o IP Tailscale)
Puerto:   22
Usuario:  musicupload
```

- [ ] Conexión SFTP exitosa
- [ ] Visible la carpeta `/music`
- [ ] Prueba de escritura: sube un archivo MP3 de prueba
- [ ] Navidrome detecta la nueva canción tras escanear

---

## Fase 5 — Cliente iOS (Amperfy / NaviBeat)

**Configuración del servidor en la app:**

| Campo | Valor |
|---|---|
| Tipo | Subsonic / OpenSubsonic |
| URL | `http://pimusic:4533` |
| Usuario | el que creaste en Navidrome |
| Contraseña | la que creaste en Navidrome |

- [ ] App conecta al servidor
- [ ] Biblioteca sincronizada
- [ ] Reproducción funciona correctamente
- [ ] Funciona fuera de casa (datos móviles + Tailscale)

---

## Prueba de extremo a extremo

1. [ ] Sube un MP3 de prueba desde iPhone por SFTP
2. [ ] Fuerza escaneo en Navidrome
3. [ ] Abre Amperfy → la canción aparece en la biblioteca
4. [ ] Reproduce la canción en el iPhone
5. [ ] Desactiva Wi-Fi en el iPhone (solo datos móviles)
6. [ ] Tailscale sigue conectado
7. [ ] La canción sigue reproduciéndose

**Todo funciona = servidor operativo.**

---

## Comandos útiles de mantenimiento

```bash
# Ver logs de Navidrome
docker compose -f ~/axcenmusic/docker-compose.yml logs -f navidrome

# Actualizar Navidrome a la última versión
cd ~/axcenmusic
docker compose pull && docker compose up -d

# Ver uso de disco
df -h

# Ver uso de RAM
free -h

# Estado general
htop

# Reiniciar todo el stack
sudo systemctl restart axcenmusic

# Ver IP Tailscale
tailscale ip -4

# Forzar escaneo de biblioteca (API)
curl -X POST "http://localhost:4533/rest/startScan.view?u=admin&p=PASSWORD&v=1.16.1&c=cli&f=json"
```

---

## Acceso a todas las apps desde un solo icono (Home Screen)

El panel `homepage/index.html` agrupa tarjetas a Navidrome, WebQueue, Lidarr,
Prowlarr, Soulseek y el editor de tags. Se despliega como contenedor
`axcen-homepage` (puerto `HOMEPAGE_PORT`, por defecto `7575`).

1. Ejecuta `sudo bash scripts/09-setup-funnel.sh` (publica Navidrome en 443,
   WebQueue en 8443 y el panel en 10000).
2. En el iPhone, abre Safari en `https://<tu-tailnet>.ts.net:10000`.
3. Compartir → **Añadir a pantalla de inicio**.

Ese único icono abre el panel con tarjetas a todas las apps; las que
requieren Tailscale (Lidarr, Prowlarr, Soulseek, tags) solo funcionarán
con la VPN activa en el iPhone.

## Una canción "vieja" sigue sonando tras subir una versión nueva

Esto no es un fallo de Navidrome: pasa por caché, no por datos corruptos.

1. **Sube el archivo nuevo con el mismo nombre/ruta** (sobrescribiendo) o,
   mejor, borra primero el archivo viejo por SFTP y luego sube el nuevo.
2. **Fuerza un escaneo completo** (no incremental):
   ```bash
   curl -X POST "http://localhost:4533/rest/startScan.view?u=admin&p=PASSWORD&v=1.16.1&c=cli&f=json&fullScan=true"
   ```
3. **Limpia la caché del cliente** (Amperfy/NaviBeat/navegador): la app
   suele cachear el audio descargado. Borra la canción de "descargas
   offline" en la app y/o cierra y reabre la app para que vuelva a pedir
   el stream al servidor.
4. Si usas el navegador, fuerza recarga sin caché (Cmd/Ctrl+Shift+R) o
   borra los datos de sitio de Navidrome.
5. Comprueba en Navidrome (Música → busca la canción → "..." → info) que
   la ruta y el tamaño del archivo corresponden a la versión nueva; si no,
   el escaneo aún no detectó el cambio.
