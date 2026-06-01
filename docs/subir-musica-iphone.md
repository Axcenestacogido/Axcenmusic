# Subir música desde iPhone por SFTP

Esta guía explica cómo subir archivos de música a tu Raspberry Pi desde el iPhone usando SFTP a través de Tailscale.

---

## Requisitos previos

- Tailscale instalado y activo en el iPhone
- Script `05-setup-sftp.sh` ejecutado en la Pi
- App SFTP en el iPhone (ver opciones más abajo)

---

## Opciones de app SFTP para iPhone

### Opción A — FE File Explorer (recomendada, gratis con limitaciones)

**App Store:** FE File Explorer — File Manager

1. Abrir FE File Explorer
2. Pulsar `+` → **Linux (SFTP)**
3. Rellenar datos de conexión:
   - **Display Name:** Pi Música
   - **Host:** `pimusic` (nombre Tailscale) o la IP Tailscale de la Pi (ej. `100.x.x.x`)
   - **Port:** `22` (o el que configuraste en `SSH_PORT`)
   - **Username:** `musicupload`
   - **Password:** la que estableciste con `passwd musicupload`
4. Pulsar **Connect**
5. Verás la carpeta `/music` — esa es la raíz de tu biblioteca

### Opción B — Secure ShellFish (de pago, muy completo)

**App Store:** Secure ShellFish — SSH/SFTP

1. Ajustes → Hosts → `+`
2. Host: `pimusic` o IP Tailscale
3. Port: `22`
4. User: `musicupload`
5. Authentication: Password
6. El explorador de archivos tiene integración con la app Archivos de iOS

### Opción C — Owlfiles (gratis)

**App Store:** Owlfiles - File Manager

Similar a FE File Explorer. SFTP → nuevo servidor → mismos datos.

---

## Flujo de trabajo para subir música

### Desde música en iCloud / archivos locales

1. Activa Tailscale en el iPhone (icono en Control Center o abrir app)
2. Abre tu app SFTP → conecta a la Pi
3. Navega a `/music/`
4. Crea la estructura de carpetas:
   ```
   /music/
   └── Artista/
       └── Album (Año)/
           ├── 01 - Cancion.mp3
           ├── 02 - Cancion.mp3
           └── cover.jpg
   ```
5. Sube los archivos desde el explorador de la app

### Desde Spotify / Apple Music (audio descargado)

Los archivos de Spotify/Apple Music tienen DRM y **no pueden transferirse directamente**.

Alternativas:
- Compra digital en Bandcamp, iTunes Store, o Beatport
- Rips de CD con formato FLAC usando XLD (Mac) o dBpoweramp (Windows)
- Archivos MP3/FLAC propios ya en tu ordenador

### Organización recomendada de carpetas

```
/music/
├── Artista A/
│   ├── Album 1 (2010)/
│   │   ├── 01 - Cancion Uno.flac
│   │   ├── 02 - Cancion Dos.flac
│   │   └── cover.jpg
│   └── Album 2 (2015)/
│       └── ...
└── Artista B/
    └── ...
```

Navidrome lee los metadatos ID3/Vorbis de los archivos. Cuanto mejor estén los tags, mejor se verá en la app.

---

## Triggear un escaneo tras subir música

Navidrome escanea automáticamente según `ND_SCAN_SCHEDULE` (por defecto cada hora).

Para forzar un escaneo inmediato:
1. Abre Navidrome en el navegador o en Amperfy → menú administración
2. **Opciones → Escanear biblioteca** (o el ícono de refresco)

O desde SSH:
```bash
curl -X POST http://localhost:4533/rest/startScan.view \
  -d "u=admin&p=tuPassword&v=1.16.1&c=curl&f=json"
```

---

## Consejos para archivos grandes (álbumes FLAC)

- Conecta el iPhone a **Wi-Fi** antes de transferir — más rápido y sin consumir datos
- Tailscale funciona sobre Wi-Fi y datos móviles; la velocidad depende de la conexión
- Para transferencias masivas iniciales, es más eficiente copiar desde un ordenador:
  ```bash
  # Desde tu Mac/Linux:
  rsync -avz --progress ~/Música/ pi@pimusic:/mnt/music/
  ```

---

## Troubleshooting

| Problema | Solución |
|---|---|
| No conecta por SFTP | Verifica que Tailscale está activo en el iPhone y que la Pi aparece como online |
| Acceso denegado | Verifica usuario `musicupload` y contraseña |
| Directorio `/music` vacío | El HDD puede no estar montado — SSH a la Pi y ejecuta `df -h` |
| Navidrome no muestra la música subida | Fuerza un escaneo desde la interfaz web |
| Error de permisos al subir | El usuario `musicupload` necesita permisos de escritura en `/mnt/music` |

Para el último caso:
```bash
sudo chown -R musicupload:sftpusers /mnt/music
sudo chmod -R 775 /mnt/music
```
