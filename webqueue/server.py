#!/usr/bin/env python3
"""
Axcenmusic — Interfaz web
- Subir archivos de música directamente desde el navegador
- Descargar desde YouTube / Bandcamp / SoundCloud via yt-dlp
- Buscar en YouTube y descargar resultados
- Disparar escaneo de biblioteca en Navidrome
Accesible solo via Tailscale: http://pimusic:8888
"""
import os
import re
import json
import base64
import shutil
import tempfile
import queue
import threading
import subprocess
import html
import time
import urllib.request
import urllib.parse
import concurrent.futures
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, unquote_plus
from datetime import datetime

# ── Configuración ──────────────────────────────────────────────────────────────
PORT             = int(os.environ.get('WEBQUEUE_PORT', '8888'))
MUSIC_DIR        = os.environ.get('MUSIC_DIR', '/mnt/music')
NTFY_TOPIC       = os.environ.get('NTFY_TOPIC', '')
ND_URL           = os.environ.get('ND_URL', 'http://localhost:4533')
ND_ADMIN_USER    = os.environ.get('ND_ADMIN_USER', '')
ND_ADMIN_PASS    = os.environ.get('ND_ADMIN_PASS', '')
MAX_UPLOAD_BYTES = int(os.environ.get('MAX_UPLOAD_MB', '500')) * 1024 * 1024

SPOTIFY_CLIENT_ID     = os.environ.get('SPOTIFY_CLIENT_ID', '')
SPOTIFY_CLIENT_SECRET = os.environ.get('SPOTIFY_CLIENT_SECRET', '')

AUDIO_EXTS = {'.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav', '.aac', '.wma', '.aiff', '.alac'}


def _make_icon_png():
    """192×192 amber PNG icon, stdlib only."""
    import zlib, struct
    w = h = 192
    row = b'\x00' + bytes([245, 158, 11] * w)  # filter=None + RGB(f59e0b)
    raw = row * h
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw))
            + chunk(b'IEND', b''))

_ICON_PNG = _make_icon_png()

_MANIFEST = json.dumps({
    "name": "Axcenmusic",
    "short_name": "Axcenmusic",
    "start_url": "/",
    "display": "standalone",
    "background_color": "#18181b",
    "theme_color": "#f59e0b",
    "icons": [
        {"src": "/icon.png", "sizes": "192x192", "type": "image/png"},
        {"src": "/icon.png", "sizes": "512x512", "type": "image/png"}
    ]
}, separators=(',', ':'))

# ── Estado compartido ──────────────────────────────────────────────────────────
download_queue = queue.Queue()
history        = []   # descargas por URL
uploads        = []   # archivos subidos directamente
current_job    = None
current_log    = []
state_lock     = threading.Lock()

# ── Cola nocturna ──────────────────────────────────────────────────────────────
night_queue = []
night_lock  = threading.Lock()

# ── Caché de carpeta de artista ────────────────────────────────────────────────
_artist_folder_cache: dict = {}
_artist_folder_cache_ts: float = 0.0

# ── Caché de tags por archivo (mtime + size) ───────────────────────────────────
_tag_cache: dict = {}  # path -> (mtime, size, tags)
_tag_cache_lock = threading.Lock()


# ── Notificación ntfy ─────────────────────────────────────────────────────────
def _notify(msg):
    if not NTFY_TOPIC:
        return
    try:
        req = urllib.request.Request(
            f'https://ntfy.sh/{NTFY_TOPIC}',
            data=msg.encode(),
            headers={'Title': 'Axcenmusic', 'Tags': 'musical_note'},
            method='POST',
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass


# ── Worker de descarga ─────────────────────────────────────────────────────────
def download_worker():
    global current_job, current_log
    while True:
        job = download_queue.get()
        with state_lock:
            current_job = job
            current_log = []
            job['status']  = 'downloading'
            job['started'] = datetime.now().strftime('%H:%M:%S')

        dest = job.get('dest', os.path.join(MUSIC_DIR, 'Descargas'))
        os.makedirs(dest, exist_ok=True)

        cmd = [
            'yt-dlp',
            '--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0',
            '--embed-thumbnail', '--embed-metadata', '--add-metadata',
            '--output', os.path.join(dest, '%(artist)s - %(title)s.%(ext)s'),
            '--newline',
            job['url'],
        ]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, bufsize=1)
            for line in proc.stdout:
                line = line.rstrip()
                with state_lock:
                    current_log.append(line)
                    if len(current_log) > 80:
                        current_log.pop(0)
            proc.wait()
            success = proc.returncode == 0
        except Exception as e:
            with state_lock:
                current_log.append(f'Error: {e}')
            success = False

        with state_lock:
            job['status']   = 'done' if success else 'error'
            job['finished'] = datetime.now().strftime('%H:%M:%S')
            job['log']      = list(current_log)
            history.insert(0, job)
            if len(history) > 30:
                history.pop()
            current_job = None
            current_log = []

        if success:
            _notify(f"Descarga completada: {job['url'][:60]}")
        download_queue.task_done()


threading.Thread(target=download_worker, daemon=True).start()


# ── Worker nocturno ────────────────────────────────────────────────────────────
def _night_worker():
    """Espera hasta las 02:00 cada día y despacha la cola nocturna."""
    while True:
        now = datetime.now()
        # Calcular segundos hasta las 02:00
        target_hour = 2
        seconds_until = ((target_hour - now.hour - 1) * 3600
                         + (60 - now.minute - 1) * 60
                         + (60 - now.second)) % 86400
        if seconds_until == 0:
            seconds_until = 86400
        time.sleep(seconds_until)
        with night_lock:
            jobs = list(night_queue)
            night_queue.clear()
        for job in jobs:
            download_queue.put(job)
        if jobs:
            _notify(f'Cola nocturna: {len(jobs)} descarga(s) iniciadas')


threading.Thread(target=_night_worker, daemon=True).start()


# ── Streaming multipart/form-data → disco ────────────────────────────────────
def _stream_upload(rfile, content_type, total_length, music_dir):
    """
    Parsea multipart/form-data escribiendo cada archivo directamente a disco.
    Nunca retiene más de ~128 KB en RAM independientemente del tamaño total.
    Devuelve (ok_files: list[str], last_dest: str, errors: list[str])
    """
    m = re.search(r'boundary=([^\s;]+)', content_type)
    if not m:
        return [], music_dir, ['Content-Type sin boundary']

    boundary = ('--' + m.group(1).strip('"')).encode()
    CHUNK    = 65536
    OVERLAP  = len(boundary) + 8  # bytes a conservar entre lecturas

    buf       = b''
    remaining = total_length
    fields    = {}
    ok_files  = []
    errors    = []
    last_dest = os.path.join(music_dir, 'Subidas')

    out_fh    = None   # handle del archivo en curso
    out_path  = None
    out_sname = None
    field_key = None
    field_val = b''

    def _read():
        nonlocal buf, remaining
        if remaining <= 0:
            return
        chunk = rfile.read(min(CHUNK, remaining))
        if chunk:
            buf       += chunk
            remaining -= len(chunk)

    def _close_part(tail):
        nonlocal out_fh, out_path, out_sname, field_key, field_val
        if tail.endswith(b'\r\n'):
            tail = tail[:-2]
        if out_fh is not None:
            try:
                out_fh.write(tail)
                out_fh.close()
                size_mb = f'{os.path.getsize(out_path) / 1048576:.1f} MB'
                with state_lock:
                    uploads.insert(0, {
                        'filename': out_sname,
                        'status':   'done',
                        'size':     size_mb,
                        'time':     datetime.now().strftime('%H:%M:%S'),
                    })
                    if len(uploads) > 50:
                        uploads.pop()
                ok_files.append(out_sname)
            except Exception as e:
                errors.append(f'{out_sname}: {e}')
            finally:
                out_fh = out_path = out_sname = None
        elif field_key is not None:
            field_val += tail
            fields[field_key] = field_val.decode('utf-8', errors='replace')
            field_key = None
            field_val = b''

    while True:
        # Leer hasta tener suficientes datos para detectar el boundary
        while boundary not in buf and remaining > 0:
            _read()

        pos = buf.find(boundary)
        if pos == -1:
            _close_part(buf)
            break

        _close_part(buf[:pos])
        buf = buf[pos + len(boundary):]

        # Comprobar marcador de fin: boundary + '--'
        while len(buf) < 4 and remaining > 0:
            _read()
        if buf.startswith(b'--'):
            break

        if buf.startswith(b'\r\n'):
            buf = buf[2:]

        # Leer cabeceras de la parte
        while b'\r\n\r\n' not in buf and remaining > 0:
            _read()
        hdr_end = buf.find(b'\r\n\r\n')
        if hdr_end == -1:
            break

        raw_hdrs = buf[:hdr_end].decode('utf-8', errors='replace')
        buf      = buf[hdr_end + 4:]

        hdrs = {}
        for line in raw_hdrs.split('\r\n'):
            if ':' in line:
                k, v = line.split(':', 1)
                hdrs[k.strip().lower()] = v.strip()

        cd = hdrs.get('content-disposition', '')
        nm = re.search(r'name="([^"]*)"', cd)
        fm = re.search(r'filename="([^"]*)"', cd)
        if not nm:
            continue

        if fm:
            filename  = fm.group(1)
            ext       = Path(filename).suffix.lower()
            field_key = None
            field_val = b''

            if ext not in AUDIO_EXTS:
                errors.append(f'{filename} (formato no soportado)')
                out_fh = None
            else:
                subfolder = (fields.get('subfolder') or 'Subidas').strip() or 'Subidas'
                dest      = os.path.join(music_dir, subfolder)
                last_dest = dest
                try:
                    os.makedirs(dest, exist_ok=True)
                except PermissionError:
                    errors.append(f'Sin permisos: sudo chown -R pi:pi {music_dir}')
                    out_fh = None
                    continue

                safe = re.sub(r'[^\w\s\-\.\(\)\[\]áéíóúüñÁÉÍÓÚÜÑ]', '_', filename)
                safe = re.sub(r'_+', '_', safe).strip('_')
                path = os.path.join(dest, safe)
                if os.path.exists(path):
                    base, suf = os.path.splitext(safe)
                    path = os.path.join(dest, f'{base}_{int(datetime.now().timestamp())}{suf}')
                try:
                    out_fh    = open(path, 'wb')
                    out_path  = path
                    out_sname = safe
                except Exception as e:
                    errors.append(f'{filename}: {e}')
                    out_fh = None
        else:
            out_fh    = None
            field_key = nm.group(1)
            field_val = b''

        # Transmitir cuerpo de la parte a disco, conservando OVERLAP bytes
        while boundary not in buf and remaining > 0:
            if len(buf) > OVERLAP:
                to_write = buf[:len(buf) - OVERLAP]
                if out_fh is not None:
                    out_fh.write(to_write)
                elif field_key is not None:
                    field_val += to_write
                buf = buf[len(buf) - OVERLAP:]
            _read()

    return ok_files, last_dest, errors


# ── Conversión a MP3 ──────────────────────────────────────────────────────────
def _convert_to_mp3(file_path):
    """Convierte un archivo de audio a MP3 320kbps. Devuelve la ruta final."""
    suffix = Path(file_path).suffix.lower()
    if suffix == '.mp3':
        return file_path
    mp3_path = file_path[:-len(suffix)] + '.mp3'
    try:
        cmd = ['ffmpeg', '-y', '-i', file_path,
               '-codec:a', 'libmp3lame', '-b:a', '320k',
               '-map_metadata', '0', '-id3v2_version', '3',
               mp3_path]
        r = subprocess.run(cmd, capture_output=True, timeout=300)
        if r.returncode == 0:
            os.remove(file_path)
            return mp3_path
    except Exception:
        pass
    return file_path  # devuelve el original si falla


# ── Portada automática ────────────────────────────────────────────────────────
def _fetch_cover_art(artist, title):
    """Descarga portada de iTunes API. Devuelve bytes o None."""
    try:
        term = urllib.parse.quote(f'{artist} {title}')
        url  = f'https://itunes.apple.com/search?term={term}&entity=song&limit=1&media=music'
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.loads(r.read())
        results = data.get('results', [])
        if not results:
            return None
        artwork_url = results[0].get('artworkUrl100', '')
        if not artwork_url:
            return None
        artwork_url = artwork_url.replace('100x100bb', '600x600bb')
        with urllib.request.urlopen(artwork_url, timeout=10) as r:
            return r.read()
    except Exception:
        return None


def _has_cover(file_path):
    """Devuelve True si el archivo ya tiene portada embebida."""
    try:
        cmd = ['ffprobe', '-v', 'quiet', '-print_format', 'json',
               '-show_streams', file_path]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        streams = json.loads(r.stdout).get('streams', [])
        for s in streams:
            codec_type = s.get('codec_type', '')
            if codec_type in ('video', 'attachment'):
                return True
        return False
    except Exception:
        return False


def _get_artist_folder(artist_name):
    """Returns path of first folder containing a song tagged with this artist. Cached 5 min."""
    global _artist_folder_cache, _artist_folder_cache_ts
    now = time.time()
    if now - _artist_folder_cache_ts > 300:
        _artist_folder_cache = {}
        _artist_folder_cache_ts = now
    key = artist_name.lower().strip()
    if key in _artist_folder_cache:
        return _artist_folder_cache[key]
    result = None
    for root, _, files in os.walk(MUSIC_DIR):
        if result:
            break
        for fn in files:
            if Path(fn).suffix.lower() not in AUDIO_EXTS:
                continue
            tags = _read_tags(os.path.join(root, fn))
            if (tags.get('artist') or '').lower().strip() == key:
                result = root
                break
    _artist_folder_cache[key] = result
    return result


def _get_artist_cover(artist_name):
    """Returns (bytes, mime) for artist.jpg/png in the artist's folder, or (None, None)."""
    folder = _get_artist_folder(artist_name)
    if not folder:
        return None, None
    for fname in ('artist.jpg', 'artist.jpeg', 'artist.png'):
        p = os.path.join(folder, fname)
        if os.path.isfile(p):
            try:
                with open(p, 'rb') as f:
                    data = f.read()
                mime = 'image/png' if fname.endswith('.png') else 'image/jpeg'
                return data, mime
            except Exception:
                pass
    return None, None


def _post_upload(folder):
    """Convierte a MP3, descarga portadas, letras y lanza escaneo."""
    # 1. Convertir todos los no-MP3 de la carpeta
    for root, _, files in os.walk(folder):
        for fn in files:
            ext = Path(fn).suffix.lower()
            if ext in AUDIO_EXTS and ext != '.mp3':
                _convert_to_mp3(os.path.join(root, fn))

    # 2. Portada automática para MP3 sin portada
    for root, _, files in os.walk(folder):
        for fn in sorted(files):
            if Path(fn).suffix.lower() != '.mp3':
                continue
            fp = os.path.join(root, fn)
            if _has_cover(fp):
                continue
            tags = _read_tags(fp)
            artist = tags.get('artist', '')
            title  = tags.get('title', Path(fn).stem)
            if not artist and not title:
                continue
            cover = _fetch_cover_art(artist, title)
            if cover:
                _write_tags(fp, None, None, None, None, cover)

    # 3. Letras
    script = Path(__file__).parent.parent / 'scripts' / 'lyrics.sh'
    if script.exists():
        try:
            subprocess.run(['bash', str(script), folder], timeout=300)
        except Exception:
            pass

    # 4. Escaneo de Navidrome
    _trigger_scan()


# ── Letras automáticas (para descargas por URL) ───────────────────────────────
def _run_lyrics(folder):
    script = Path(__file__).parent.parent / 'scripts' / 'lyrics.sh'
    if not script.exists():
        return
    try:
        subprocess.run(['bash', str(script), folder], timeout=300)
    except Exception:
        pass


# ── Trigger scan en Navidrome ─────────────────────────────────────────────────
def _trigger_scan():
    if not ND_ADMIN_USER or not ND_ADMIN_PASS:
        return False, 'ND_ADMIN_USER / ND_ADMIN_PASS no configurados en .env'
    url = (f'{ND_URL}/rest/startScan.view'
           f'?u={ND_ADMIN_USER}&p={ND_ADMIN_PASS}&v=1.16.1&c=webqueue&f=json')
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return True, 'Escaneo iniciado'
    except Exception as e:
        return False, str(e)


# ── Biblioteca: listar, leer tags, portada, editar, eliminar ─────────────────

def _safe_path(b64):
    """Decodifica y valida que la ruta esté dentro de MUSIC_DIR."""
    try:
        path = base64.b64decode(b64.encode()).decode()
    except Exception:
        return None
    path = os.path.realpath(path)
    if not path.startswith(os.path.realpath(MUSIC_DIR) + os.sep):
        return None
    return path

def _read_tags(file_path):
    try:
        cmd = ['ffprobe', '-v', 'quiet', '-print_format', 'json',
               '-show_format', file_path]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        tags = json.loads(r.stdout).get('format', {}).get('tags', {})
        return {k.lower(): v for k, v in tags.items()}
    except Exception:
        return {}

def _read_tags_cached(file_path):
    """Like _read_tags but caches by (mtime, size) — avoids ffprobe for unchanged files."""
    try:
        st = os.stat(file_path)
        key = (st.st_mtime, st.st_size)
        with _tag_cache_lock:
            entry = _tag_cache.get(file_path)
        if entry and entry[0] == key[0] and entry[1] == key[1]:
            return entry[2]
        tags = _read_tags(file_path)
        with _tag_cache_lock:
            _tag_cache[file_path] = (key[0], key[1], tags)
        return tags
    except Exception:
        return _read_tags(file_path)

def _list_songs():
    paths = []
    for root, _, files in os.walk(MUSIC_DIR):
        for fn in sorted(files):
            if Path(fn).suffix.lower() not in AUDIO_EXTS:
                continue
            paths.append(os.path.join(root, fn))

    def _process(path):
        try:
            tags = _read_tags_cached(path)
            fn = os.path.basename(path)
            return {
                'p': base64.b64encode(path.encode()).decode(),
                'f': fn,
                'r': os.path.relpath(path, MUSIC_DIR),
                't': tags.get('title', Path(fn).stem),
                'ar': tags.get('artist', ''),
                'al': tags.get('album', ''),
                'ge': tags.get('genre', ''),
                'sz': f'{os.path.getsize(path) / 1048576:.1f} MB',
            }
        except Exception:
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = ex.map(_process, paths)
    return [r for r in results if r is not None]

def _get_cover_bytes(file_path):
    try:
        cmd = ['ffmpeg', '-i', file_path, '-an', '-vframes', '1',
               '-f', 'image2', '-vcodec', 'copy', 'pipe:1']
        r = subprocess.run(cmd, capture_output=True, timeout=10)
        if r.returncode == 0 and len(r.stdout) > 100:
            return r.stdout, 'image/jpeg'
    except Exception:
        pass
    return None, None

def _write_tags(file_path, title, artist, album, genre=None, cover_data=None):
    suffix = Path(file_path).suffix.lower()
    tmp    = file_path + '.__edit' + suffix
    ctmp   = None

    # Formatos que no soportan portada embebida
    NO_COVER = {'.wav', '.aiff', '.aif', '.wma'}
    # Formatos que usan ID3v2 (solo MP3)
    USE_ID3  = {'.mp3'}

    use_cover = cover_data and suffix not in NO_COVER

    try:
        cmd = ['ffmpeg', '-y', '-i', file_path]

        if use_cover:
            ctmp = tempfile.NamedTemporaryFile(suffix='.jpg', delete=False)
            ctmp.write(cover_data)
            ctmp.close()
            cmd += ['-i', ctmp.name, '-map', '0:a', '-map', '1:0']

        cmd += ['-codec', 'copy', '-map_metadata', '0']

        if suffix in USE_ID3:
            cmd += ['-id3v2_version', '3']

        if title  is not None: cmd += ['-metadata', f'title={title}']
        if artist is not None: cmd += ['-metadata', f'artist={artist}']
        if album  is not None: cmd += ['-metadata', f'album={album}']
        if genre  is not None: cmd += ['-metadata', f'genre={genre}']

        if use_cover:
            cmd += ['-metadata:s:v', 'title=Album cover',
                    '-metadata:s:v', 'comment=Cover (front)',
                    '-disposition:v', 'attached_pic']

        cmd.append(tmp)
        r = subprocess.run(cmd, capture_output=True, timeout=60)
        if r.returncode == 0:
            shutil.move(tmp, file_path)
            return True, ''
        return False, r.stderr.decode(errors='replace')[-300:]
    except Exception as e:
        return False, str(e)
    finally:
        if ctmp and os.path.exists(ctmp.name):
            try: os.unlink(ctmp.name)
            except: pass
        if os.path.exists(tmp):
            try: os.unlink(tmp)
            except: pass


# ── Búsqueda YouTube ──────────────────────────────────────────────────────────
def _yt_search(query):
    """Busca en YouTube vía yt-dlp. Devuelve lista de dicts."""
    cmd = [
        'yt-dlp',
        f'ytsearch8:{query}',
        '--dump-json', '--skip-download', '--no-warnings',
    ]
    results = []
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
                vid_id = item.get('id', '')
                results.append({
                    'id':              vid_id,
                    'title':           item.get('title', ''),
                    'uploader':        item.get('uploader', item.get('channel', '')),
                    'duration_string': item.get('duration_string', ''),
                    'url':             f'https://youtube.com/watch?v={vid_id}',
                })
            except Exception:
                pass
    except Exception:
        pass
    return results


# ── Duplicados ────────────────────────────────────────────────────────────────
def _find_duplicates():
    """Agrupa archivos con mismo título+artista (normalizado). Devuelve grupos con 2+ archivos."""
    groups = {}
    for root, _, files in os.walk(MUSIC_DIR):
        for fn in sorted(files):
            if Path(fn).suffix.lower() not in AUDIO_EXTS:
                continue
            path = os.path.join(root, fn)
            try:
                tags   = _read_tags(path)
                title  = tags.get('title', Path(fn).stem).lower().strip()
                artist = tags.get('artist', '').lower().strip()
                key    = f'{artist}||{title}'
                if key not in groups:
                    groups[key] = []
                groups[key].append({
                    'p':  base64.b64encode(path.encode()).decode(),
                    'f':  fn,
                    'r':  os.path.relpath(path, MUSIC_DIR),
                    't':  tags.get('title', Path(fn).stem),
                    'ar': tags.get('artist', ''),
                    'sz': f'{os.path.getsize(path) / 1048576:.1f} MB',
                })
            except Exception:
                pass
    return [v for v in groups.values() if len(v) >= 2]


# ── Estadísticas de la biblioteca ─────────────────────────────────────────────
def _get_library_stats():
    songs = 0
    artists_set = set()
    albums_set  = set()
    total_secs  = 0.0
    total_bytes = 0
    with_cover  = 0
    with_lyrics = 0
    for root, _, files in os.walk(MUSIC_DIR):
        for fn in files:
            ext = Path(fn).suffix.lower()
            if ext not in AUDIO_EXTS:
                continue
            path = os.path.join(root, fn)
            songs += 1
            try: total_bytes += os.path.getsize(path)
            except: pass
            tags = _read_tags(path)
            if tags.get('artist'): artists_set.add(tags['artist'])
            if tags.get('album'):  albums_set.add(tags['album'])
            try:
                cmd = ['ffprobe', '-v', 'quiet', '-show_entries', 'format=duration',
                       '-of', 'default=noprint_wrappers=1:nokey=1', path]
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                total_secs += float(r.stdout.strip() or 0)
            except: pass
            lrc = path[:-len(ext)] + '.lrc'
            if os.path.exists(lrc): with_lyrics += 1
            if _has_cover(path):    with_cover  += 1
    h = int(total_secs // 3600)
    m = int((total_secs % 3600) // 60)
    return {
        'songs':       songs,
        'artists':     len(artists_set),
        'albums':      len(albums_set),
        'duration':    f'{h}h {m}m',
        'size_gb':     round(total_bytes / 1_073_741_824, 2),
        'with_cover':  with_cover,
        'with_lyrics': with_lyrics,
    }


# ── Escáner de calidad ────────────────────────────────────────────────────────
def _scan_quality():
    issues = []
    for root, _, files in os.walk(MUSIC_DIR):
        for fn in sorted(files):
            ext = Path(fn).suffix.lower()
            if ext not in AUDIO_EXTS:
                continue
            path = os.path.join(root, fn)
            tags = _read_tags(path)
            missing = []
            if not tags.get('title'):  missing.append('título')
            if not tags.get('artist'): missing.append('artista')
            if not tags.get('album'):  missing.append('álbum')
            if not _has_cover(path):   missing.append('portada')
            lrc = path[:-len(ext)] + '.lrc'
            if not os.path.exists(lrc): missing.append('letra')
            if missing:
                issues.append({
                    'p': base64.b64encode(path.encode()).decode(),
                    'f': fn,
                    'r': os.path.relpath(path, MUSIC_DIR),
                    't': tags.get('title', Path(fn).stem),
                    'ar': tags.get('artist', ''),
                    'missing': missing,
                })
    return issues


# ── yt-dlp versión ────────────────────────────────────────────────────────────
def _ytdlp_version():
    try:
        r = subprocess.run(['yt-dlp', '--version'], capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except Exception:
        return 'desconocida'


# ── Reproduciendo ahora ───────────────────────────────────────────────────────
def _now_playing():
    if not ND_ADMIN_USER or not ND_ADMIN_PASS:
        return None
    url = (f'{ND_URL}/rest/getNowPlaying.view'
           f'?u={ND_ADMIN_USER}&p={ND_ADMIN_PASS}&v=1.16.1&c=webqueue&f=json')
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
        entries = (data.get('subsonic-response', {})
                       .get('nowPlaying', {})
                       .get('entry', []))
        if not entries:
            return None
        e = entries[0] if isinstance(entries, list) else entries
        return {
            'title':    e.get('title', ''),
            'artist':   e.get('artist', ''),
            'album':    e.get('album', ''),
            'coverArt': e.get('coverArt', ''),
        }
    except Exception:
        return None


# ── Spotify ───────────────────────────────────────────────────────────────────
def _spotify_tracks(url):
    """Extrae las pistas de una playlist de Spotify. Devuelve lista de {title, artist}."""
    m = re.search(r'playlist/([A-Za-z0-9]+)', url)
    if not m:
        raise RuntimeError('URL de playlist de Spotify no válida')
    playlist_id = m.group(1)

    if not SPOTIFY_CLIENT_ID or not SPOTIFY_CLIENT_SECRET:
        raise RuntimeError('Configura SPOTIFY_CLIENT_ID y SPOTIFY_CLIENT_SECRET en .env')

    # Obtener token de acceso
    credentials = base64.b64encode(f'{SPOTIFY_CLIENT_ID}:{SPOTIFY_CLIENT_SECRET}'.encode()).decode()
    token_req = urllib.request.Request(
        'https://accounts.spotify.com/api/token',
        data=b'grant_type=client_credentials',
        headers={
            'Authorization': f'Basic {credentials}',
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        method='POST',
    )
    try:
        with urllib.request.urlopen(token_req, timeout=10) as resp:
            token_data = json.loads(resp.read())
    except Exception as e:
        raise RuntimeError(f'Error obteniendo token de Spotify: {e}')

    access_token = token_data.get('access_token', '')
    if not access_token:
        raise RuntimeError('No se pudo obtener token de Spotify')

    # Paginar tracks
    tracks = []
    api_url = (f'https://api.spotify.com/v1/playlists/{playlist_id}/tracks'
               f'?limit=50&fields=next,items(track(name,artists(name),duration_ms))')
    while api_url:
        req = urllib.request.Request(
            api_url,
            headers={'Authorization': f'Bearer {access_token}'},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                page = json.loads(resp.read())
        except Exception as e:
            raise RuntimeError(f'Error leyendo playlist de Spotify: {e}')

        for item in page.get('items', []):
            track = item.get('track')
            if not track:
                continue
            name = track.get('name', '')
            artists = track.get('artists', [])
            artist = artists[0].get('name', '') if artists else ''
            if name:
                tracks.append({'title': name, 'artist': artist})

        api_url = page.get('next')

    return tracks


# ── HTML ───────────────────────────────────────────────────────────────────────
def _badge(s):
    return {
        'downloading': '<span class="badge green">⟳ Descargando</span>',
        'done':        '<span class="badge green">✓ Listo</span>',
        'error':       '<span class="badge red">✗ Error</span>',
        'queued':      '<span class="badge yellow">· En cola</span>',
    }.get(s, s)


def render_page(flash='', flash_ok=True):
    with state_lock:
        job    = dict(current_job) if current_job else None
        log    = list(current_log)
        hist   = list(history)
        ups    = list(uploads)
        q_size = download_queue.qsize()

    with night_lock:
        nq_snap = list(night_queue)

    ytdlp_ver = _ytdlp_version()

    nd_url_js  = html.escape(ND_URL)
    nd_user_js = html.escape(ND_ADMIN_USER)
    nd_pass_js = html.escape(ND_ADMIN_PASS)

    now_playing_html = ''
    if ND_ADMIN_USER and ND_ADMIN_PASS:
        now_playing_html = (
            '<div id="np-card" style="display:none;background:#27272a;border-radius:12px;'
            'padding:12px 16px;margin-bottom:12px;display:flex;align-items:center;gap:12px">'
            '<img id="np-cover" src="" style="width:48px;height:48px;object-fit:cover;border-radius:6px;background:#3f3f46;flex-shrink:0">'
            '<div style="min-width:0">'
            '<div style="font-size:.7rem;color:#71717a;text-transform:uppercase;letter-spacing:.05em">Reproduciendo ahora</div>'
            '<div id="np-title" style="font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>'
            '<div id="np-artist" style="color:#a1a1aa;font-size:.82rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>'
            '</div>'
            '<span style="margin-left:auto;color:#4ade80;font-size:1.2rem;flex-shrink:0">♪</span>'
            '</div>'
        )

    # Historial descargas
    dl_rows = ''
    for h in hist[:10]:
        dl_rows += f'''<tr>
          <td>{_badge(h["status"])}</td>
          <td class="url-cell">{html.escape(h["url"][:60])}</td>
          <td>{html.escape(h.get("started",""))}</td>
        </tr>'''
    dl_hist = f'''<table><tr><th>Estado</th><th>URL</th><th>Hora</th></tr>{dl_rows}</table>''' \
              if hist else '<p class="muted">Sin descargas todavía.</p>'

    # Historial subidas
    up_rows = ''
    for u in ups[:15]:
        up_rows += f'''<tr>
          <td>{_badge(u["status"])}</td>
          <td>{html.escape(u["filename"])}</td>
          <td>{html.escape(u.get("size",""))}</td>
          <td>{html.escape(u.get("time",""))}</td>
        </tr>'''
    up_hist = f'''<table><tr><th>Estado</th><th>Archivo</th><th>Tamaño</th><th>Hora</th></tr>{up_rows}</table>''' \
              if ups else '<p class="muted">Sin subidas todavía.</p>'

    # Botón de escaneo
    scan_btn = ''
    if ND_ADMIN_USER and ND_ADMIN_PASS:
        scan_btn = '''
        <form method="post" action="/scan" style="display:inline">
          <button type="submit" class="btn-scan">⟳ Escanear biblioteca</button>
        </form>'''

    flash_html = ''
    if flash:
        color = '#4ade80' if flash_ok else '#f87171'
        flash_html = f'<div class="flash" style="border-color:{color};color:{color}">{html.escape(flash)}</div>'

    can_scan_note = '' if (ND_ADMIN_USER and ND_ADMIN_PASS) else \
        '<p class="muted" style="margin-top:6px">Añade ND_ADMIN_USER y ND_ADMIN_PASS en .env para activar el botón de escaneo.</p>'

    # Noche queue initial JSON for JS
    nq_json = json.dumps(nq_snap)

    return f'''<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Axcenmusic</title>
  <link rel="manifest" href="/manifest.json">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="Axcenmusic">
  <link rel="apple-touch-icon" href="/icon.png">
  <meta name="theme-color" content="#f59e0b">
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    body{{background:#18181b;color:#e4e4e7;font-family:system-ui,sans-serif;
         padding:16px;max-width:860px;margin:0 auto}}
    h1{{color:#f59e0b;font-size:1.4rem;margin-bottom:2px}}
    .sub{{color:#71717a;font-size:.82rem;margin-bottom:16px}}
    .card{{background:#27272a;border-radius:12px;padding:18px;margin:12px 0}}
    .card-title{{color:#a1a1aa;font-size:.9rem;font-weight:600;
                 text-transform:uppercase;letter-spacing:.05em;margin-bottom:12px}}
    label{{display:block;color:#a1a1aa;font-size:.85rem;margin-bottom:4px}}
    input[type=url],input[type=text],input[type=search]{{
      background:#3f3f46;border:1px solid #52525b;color:#e4e4e7;
      border-radius:8px;padding:9px 12px;width:100%;font-size:.95rem;margin-bottom:10px}}
    input[type=url]:focus,input[type=text]:focus,input[type=search]:focus{{outline:none;border-color:#f59e0b}}
    .btn{{background:#f59e0b;color:#18181b;border:none;border-radius:8px;
          padding:11px 22px;font-size:1rem;font-weight:700;cursor:pointer;
          width:100%;margin-top:4px}}
    .btn:hover{{background:#fbbf24}}
    .btn-scan{{background:#3f3f46;color:#e4e4e7;border:none;border-radius:8px;
               padding:9px 18px;font-size:.9rem;font-weight:600;cursor:pointer}}
    .btn-scan:hover{{background:#52525b}}
    .btn-sm{{background:#3f3f46;color:#e4e4e7;border:none;border-radius:6px;
             padding:5px 10px;font-size:.8rem;font-weight:600;cursor:pointer}}
    .btn-sm:hover{{background:#52525b}}
    .btn-night{{background:#312e81;color:#c7d2fe;border:none;border-radius:6px;
                padding:5px 10px;font-size:.8rem;font-weight:600;cursor:pointer}}
    .btn-night:hover{{background:#3730a3}}
    .btn-dl{{background:#14532d;color:#4ade80;border:none;border-radius:6px;
             padding:5px 10px;font-size:.8rem;font-weight:600;cursor:pointer}}
    .btn-dl:hover{{background:#166534}}
    .badge{{border-radius:20px;padding:2px 10px;font-size:.78rem;font-weight:600}}
    .badge.green{{background:#14532d;color:#4ade80}}
    .badge.red{{background:#450a0a;color:#f87171}}
    .badge.yellow{{background:#422006;color:#fbbf24}}
    pre.logbox{{background:#09090b;border-radius:8px;padding:12px;font-size:.75rem;
                overflow-x:auto;max-height:220px;overflow-y:auto;
                color:#86efac;white-space:pre-wrap;margin-top:10px}}
    table{{width:100%;border-collapse:collapse;font-size:.85rem}}
    th{{text-align:left;color:#71717a;padding:6px 8px;border-bottom:1px solid #3f3f46}}
    td{{padding:7px 8px;border-bottom:1px solid #27272a;vertical-align:middle}}
    .url-cell{{word-break:break-all;max-width:300px}}
    .muted{{color:#71717a;font-size:.85rem}}
    .flash{{border:1px solid;border-radius:8px;padding:10px 14px;
            margin-bottom:12px;font-weight:600}}
    /* Upload drop zone */
    .dropzone{{border:2px dashed #52525b;border-radius:10px;padding:28px 16px;
               text-align:center;cursor:pointer;transition:.2s;margin-bottom:10px}}
    .dropzone:hover,.dropzone.drag{{border-color:#f59e0b;background:#1c1917}}
    .dropzone-icon{{font-size:2.5rem;margin-bottom:6px}}
    .dropzone-label{{color:#a1a1aa;font-size:.9rem}}
    #file-input{{display:none}}
    #file-list{{margin:8px 0;font-size:.85rem}}
    .file-item{{background:#3f3f46;border-radius:6px;padding:6px 10px;
                margin:4px 0;display:flex;justify-content:space-between;align-items:center}}
    .file-item .fname{{color:#e4e4e7;word-break:break-all}}
    .file-item .fsize{{color:#71717a;font-size:.78rem;white-space:nowrap;margin-left:8px}}
    /* Progress */
    #progress-wrap{{display:none;margin-top:10px}}
    .progress-bar-bg{{background:#3f3f46;border-radius:20px;height:8px;overflow:hidden}}
    .progress-bar-fg{{background:#f59e0b;height:100%;border-radius:20px;
                      transition:width .2s;width:0%}}
    #progress-label{{color:#a1a1aa;font-size:.82rem;margin-top:6px;text-align:center}}
    .tabs{{display:flex;gap:8px;margin-bottom:4px}}
    .tab{{flex:1;text-align:center;padding:10px;background:#3f3f46;border-radius:8px;
           font-size:.88rem;font-weight:600;cursor:pointer;color:#a1a1aa}}
    .tab.active{{background:#f59e0b;color:#18181b}}
    .tab-content{{display:none}}
    .tab-content.active{{display:block}}
    /* Search results */
    .sr-item{{display:flex;align-items:center;gap:10px;padding:10px 0;
              border-bottom:1px solid #3f3f46}}
    .sr-info{{flex:1;min-width:0}}
    .sr-title{{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
    .sr-meta{{color:#71717a;font-size:.8rem}}
    .sr-btns{{display:flex;gap:6px;flex-shrink:0}}
    /* Library grouped */
    .artist-section{{margin-bottom:8px;border-radius:8px;overflow:hidden}}
    .artist-header{{background:#3f3f46;padding:10px 14px;cursor:pointer;
                    display:flex;align-items:center;gap:8px;font-weight:700}}
    .artist-header:hover{{background:#52525b}}
    .album-section{{margin:0;border-radius:0}}
    .album-header{{background:#2d2d30;padding:8px 14px 8px 28px;cursor:pointer;
                   display:flex;align-items:center;gap:8px;color:#a1a1aa;font-weight:600}}
    .album-header:hover{{background:#363639}}
    .song-row{{display:flex;align-items:center;gap:10px;padding:8px 14px 8px 42px;
               border-bottom:1px solid #3f3f46}}
    .song-row:last-child{{border-bottom:none}}
    .collapse-icon{{transition:transform .2s;display:inline-block}}
    .collapsed .collapse-icon{{transform:rotate(-90deg)}}
    /* Night queue */
    .nq-item{{display:flex;align-items:center;gap:8px;padding:6px 0;
              border-bottom:1px solid #3f3f46;font-size:.85rem}}
    .nq-url{{flex:1;word-break:break-all;color:#c7d2fe}}
    .artist-thumb{{width:32px;height:32px;object-fit:cover;border-radius:50%;
                   background:#3f3f46;flex-shrink:0;border:2px solid #3f3f46}}
    /* Multi-select */
    .song-row.selected{{background:#2d2b1e}}
    .bulk-bar{{position:sticky;bottom:0;background:#1c1917;border-top:1px solid #f59e0b;
               padding:10px 14px;display:flex;align-items:center;gap:10px;
               font-size:.88rem}}
  </style>
</head>
<body>
  <h1>🎵 Axcenmusic</h1>
  <p class="sub">Interfaz web · solo accesible via Tailscale</p>

  {flash_html}
  {now_playing_html}

  <div class="tabs">
    <div class="tab active" onclick="switchTab('upload')">Subir</div>
    <div class="tab" onclick="switchTab('search')">Buscar</div>
    <div class="tab" onclick="switchTab('library')">Biblioteca</div>
    <div class="tab" onclick="switchTab('history')">Historial</div>
  </div>

  <!-- ── SUBIR ARCHIVOS ── -->
  <div id="tab-upload" class="tab-content active">
    <div class="card">
      <div class="card-title">Subir música desde este dispositivo</div>
      <div class="dropzone" id="dropzone" onclick="document.getElementById('file-input').click()">
        <div class="dropzone-icon">📂</div>
        <div class="dropzone-label">Toca para elegir archivos<br>
          <span style="font-size:.78rem;color:#52525b">MP3 · FLAC · M4A · OGG · OPUS · WAV · AAC</span>
        </div>
      </div>
      <input type="file" id="file-input" multiple
             accept=".mp3,.flac,.m4a,.ogg,.opus,.wav,.aac,.wma,.aiff,.alac,audio/*">
      <div id="file-list"></div>

      <label style="margin-top:10px">Subcarpeta destino</label>
      <input type="text" id="subfolder-upload" value="Subidas" placeholder="Artista/Album">

      <div id="progress-wrap">
        <div class="progress-bar-bg"><div class="progress-bar-fg" id="progress-bar"></div></div>
        <div id="progress-label">0%</div>
      </div>

      <button class="btn" id="btn-upload" onclick="startUpload()">Subir archivos</button>
    </div>

    <div class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>Escanear biblioteca en Navidrome</span>
        {scan_btn}
      </div>
      <p class="muted">Después de subir música, toca el botón para que aparezca en NaviBeat / Amperfy.</p>
      {can_scan_note}
    </div>
  </div>

  <!-- ── BUSCAR ── -->
  <div id="tab-search" class="tab-content">
    <!-- Importar playlist de Spotify -->
    <div class="card">
      <div class="card-title">Importar playlist de Spotify</div>
      <div style="display:flex;gap:8px;margin-bottom:10px">
        <input type="url" id="spotify-url" placeholder="https://open.spotify.com/playlist/…"
               style="margin-bottom:0;flex:1" onkeydown="if(event.key==='Enter')importSpotify()">
        <button class="btn-scan" onclick="importSpotify()" style="flex-shrink:0">&#8595; Importar</button>
      </div>
      <div id="spotify-status" class="muted"><!-- status here --></div>
      <div id="spotify-list" style="margin-top:8px;font-size:.85rem"></div>
      <p class="muted" style="margin-top:8px;font-size:.78rem">
        Requiere <code>SPOTIFY_CLIENT_ID</code> y <code>SPOTIFY_CLIENT_SECRET</code> en .env
        (<a href="https://developer.spotify.com/dashboard" style="color:#f59e0b" target="_blank">developer.spotify.com</a> &#8594; Create app, gratis).
      </p>
    </div>

    <div class="card">
      <div class="card-title">Buscar en YouTube</div>
      <div style="display:flex;gap:8px;margin-bottom:10px">
        <input type="search" id="yt-query" placeholder="Artista, canción…" style="margin-bottom:0;flex:1"
               onkeydown="if(event.key==='Enter')doSearch()">
        <button class="btn-scan" onclick="doSearch()" style="flex-shrink:0">🔍 Buscar</button>
      </div>
      <div id="search-status" class="muted"></div>
      <div id="search-results"></div>
    </div>

    <!-- Cola nocturna -->
    <div class="card" id="night-card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>🌙 Cola nocturna (<span id="nq-count">0</span>)</span>
        <span class="muted" style="font-size:.78rem">Se descarga a las 02:00</span>
      </div>
      <div id="nq-list"><p class="muted">Sin elementos.</p></div>
    </div>

    <!-- Descarga manual URL -->
    <div class="card">
      <div class="card-title">Descargar desde URL</div>
      <form method="post" action="/add">
        <label>URL (YouTube, Bandcamp, SoundCloud…)</label>
        <input type="url" name="url" placeholder="https://youtube.com/watch?v=..." required>
        <label>Subcarpeta destino</label>
        <input type="text" name="subfolder" value="Descargas" placeholder="Artista/Album">
        <button type="submit" class="btn">Añadir a la cola</button>
      </form>
      <p class="muted" style="margin-top:8px">En cola: <b id="q-size-badge">{q_size}</b></p>
    </div>

    <!-- Log SSE -->
    <div class="card">
      <div class="card-title">Log de descarga en tiempo real</div>
      <pre class="logbox" id="sse-log">Esperando actividad…</pre>
    </div>

    <!-- yt-dlp actualizar -->
    <div class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>yt-dlp — versión: <span id="ytdlp-ver">{ytdlp_ver}</span></span>
        <button class="btn-scan" onclick="updateYtdlp()" id="btn-ytdlp-update">&#8593; Actualizar</button>
      </div>
      <pre class="logbox" id="ytdlp-log" style="display:none;max-height:120px"></pre>
    </div>
  </div>

  <!-- ── BIBLIOTECA ── -->
  <div id="tab-library" class="tab-content">
    <div class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>Canciones en la biblioteca</span>
        <button class="btn-scan" onclick="loadLibrary()">↺ Recargar</button>
      </div>
      <input type="search" id="lib-search" placeholder="Filtrar por título, artista o álbum…"
             style="margin-bottom:10px" oninput="filterLibrary(this.value)">
      <div id="lib-loading" class="muted">Cargando…</div>
      <div id="lib-list"></div>
      <div id="bulk-bar" class="bulk-bar" style="display:none">
        <span id="bulk-count">0 seleccionadas</span>
        <button class="btn-scan" style="margin-left:auto" onclick="bulkDelete()">🗑 Eliminar seleccionadas</button>
        <button class="btn-scan" onclick="clearSelection()">✕ Deseleccionar</button>
      </div>
    </div>

    <!-- Estadísticas -->
    <div class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>Estadísticas de la biblioteca</span>
        <button class="btn-scan" onclick="loadStats()">📊 Calcular</button>
      </div>
      <div id="stats-wrap" class="muted">Pulsa Calcular (puede tardar unos segundos).</div>
    </div>

    <!-- Calidad -->
    <div class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>Escáner de calidad</span>
        <button class="btn-scan" onclick="runQualityScan()">🔍 Escanear</button>
      </div>
      <div id="quality-status" class="muted">Pulsa Escanear para detectar canciones con metadatos incompletos.</div>
      <div id="quality-list"></div>
    </div>

    <!-- Duplicados -->
    <div class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>Duplicados</span>
        <button class="btn-scan" onclick="findDuplicates()">🔍 Buscar duplicados</button>
      </div>
      <div id="dup-status" class="muted">Pulsa el botón para buscar.</div>
      <div id="dup-list"></div>
    </div>
  </div>

  <!-- ── MODAL EDITAR ── -->
  <div id="edit-modal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.75);
       z-index:100;align-items:center;justify-content:center;padding:16px">
    <div style="background:#27272a;border-radius:14px;padding:20px;width:100%;max-width:480px">
      <div style="color:#f59e0b;font-weight:700;font-size:1.1rem;margin-bottom:14px">Editar canción</div>
      <input type="hidden" id="edit-path">

      <div style="display:flex;gap:12px;margin-bottom:14px;align-items:flex-start">
        <div style="flex:0 0 80px">
          <img id="edit-cover-preview" src="" alt="portada"
               style="width:80px;height:80px;object-fit:cover;border-radius:8px;
                      background:#3f3f46;display:block">
          <label style="display:block;text-align:center;margin-top:4px;
                        font-size:.72rem;color:#f59e0b;cursor:pointer"
                 onclick="document.getElementById('edit-cover-input').click()">
            Cambiar portada
          </label>
          <input type="file" id="edit-cover-input" accept="image/*" style="display:none"
                 onchange="previewCover(this)">
        </div>
        <div style="flex:1">
          <label>Título</label>
          <input type="text" id="edit-title" style="margin-bottom:8px">
          <label>Artista</label>
          <input type="text" id="edit-artist" style="margin-bottom:8px">
          <label>Álbum</label>
          <input type="text" id="edit-album" style="margin-bottom:8px">
          <label>Género</label>
          <input type="text" id="edit-genre" placeholder="Pop, Rock, Hip-Hop…">
        </div>
      </div>

      <div id="edit-error" style="color:#f87171;font-size:.85rem;margin-bottom:8px;display:none"></div>

      <div style="display:flex;gap:8px">
        <button class="btn" style="flex:1" onclick="saveEdit()">Guardar</button>
        <button class="btn-scan" style="flex:0 0 auto;padding:11px 18px"
                onclick="closeModal()">Cancelar</button>
      </div>
    </div>
  </div>

  <!-- ── MINI PLAYER ── -->
  <div id="player" style="display:none;position:fixed;bottom:0;left:0;right:0;
    background:#1c1917;border-top:1px solid #3f3f46;padding:10px 16px;
    z-index:200;align-items:center;gap:12px;max-width:860px;
    margin:0 auto">
    <img id="pl-cover" src="" style="width:44px;height:44px;object-fit:cover;border-radius:6px;background:#3f3f46;flex-shrink:0">
    <div style="flex:1;min-width:0">
      <div id="pl-title" style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:.9rem"></div>
      <div id="pl-artist" style="color:#71717a;font-size:.78rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"></div>
      <input type="range" id="pl-seek" value="0" min="0" max="100" step="0.1"
             style="width:100%;accent-color:#f59e0b;cursor:pointer;margin-top:2px">
    </div>
    <button id="pl-btn" onclick="togglePlay()"
      style="background:#f59e0b;color:#18181b;border:none;border-radius:50%;
             width:40px;height:40px;font-size:1.1rem;cursor:pointer;flex-shrink:0">&#9654;</button>
    <span id="pl-time" style="color:#71717a;font-size:.75rem;white-space:nowrap">0:00</span>
    <button onclick="closePlayer()"
      style="background:none;border:none;color:#71717a;font-size:1.1rem;cursor:pointer;flex-shrink:0">&#x2715;</button>
    <audio id="pl-audio"></audio>
  </div>

  <!-- ── HISTORIAL ── -->
  <div id="tab-history" class="tab-content">
    <div class="card">
      <div class="card-title">Archivos subidos</div>
      {up_hist}
    </div>
    <div class="card">
      <div class="card-title">Descargas por URL</div>
      {dl_hist}
    </div>
  </div>

  <script>
  // ── Tabs ──────────────────────────────────────────────────────────
  const TAB_NAMES = ['upload','search','library','history'];
  function switchTab(name) {{
    document.querySelectorAll('.tab').forEach(function(t, i) {{
      t.classList.toggle('active', TAB_NAMES[i] === name);
    }});
    document.querySelectorAll('.tab-content').forEach(function(c) {{ c.classList.remove('active'); }});
    document.getElementById('tab-' + name).classList.add('active');
    if (name === 'library' && !libLoaded) loadLibrary();
  }}

  // ── SSE ───────────────────────────────────────────────────────────
  (function() {{
    const logEl = document.getElementById('sse-log');
    const qEl   = document.getElementById('q-size-badge');
    let logLines = [];
    const es = new EventSource('/events');
    es.onmessage = function(e) {{
      let d;
      try {{ d = JSON.parse(e.data); }} catch(ex) {{ return; }}
      if (d.q !== undefined && qEl) qEl.textContent = d.q;
      if (d.log && d.log.length) {{
        for (let i = 0; i < d.log.length; i++) {{
          logLines.push(d.log[i]);
        }}
        if (logLines.length > 60) logLines = logLines.slice(logLines.length - 60);
        logEl.textContent = logLines.join('\\n');
        logEl.scrollTop = logEl.scrollHeight;
      }}
      if (d.job && d.job.url) {{
        logEl.textContent = '[Descargando] ' + d.job.url + '\\n' + logLines.join('\\n');
        logEl.scrollTop = logEl.scrollHeight;
      }}
    }};
    es.onerror = function() {{
      setTimeout(function() {{
        try {{ es.close(); }} catch(ex) {{}}
      }}, 3000);
    }};
  }})();

  // ── Búsqueda YouTube ──────────────────────────────────────────────
  async function doSearch() {{
    const q = document.getElementById('yt-query').value.trim();
    if (!q) return;
    const statusEl  = document.getElementById('search-status');
    const resultsEl = document.getElementById('search-results');
    statusEl.textContent  = 'Buscando…';
    resultsEl.innerHTML   = '';
    try {{
      const r    = await fetch('/api/search?q=' + encodeURIComponent(q));
      const data = await r.json();
      statusEl.textContent = data.length ? data.length + ' resultados' : 'Sin resultados.';
      resultsEl.innerHTML  = data.map(function(item) {{
        const safeTitle    = escHtml(item.title);
        const safeUploader = escHtml(item.uploader);
        const safeDur      = escHtml(item.duration_string);
        const safeUrlAttr  = escHtml(item.url);
        return '<div class="sr-item">'
          + '<div class="sr-info">'
          + '<div class="sr-title">' + safeTitle + '</div>'
          + '<div class="sr-meta">' + safeUploader + ' &middot; ' + safeDur + '</div>'
          + '</div>'
          + '<div class="sr-btns">'
          + '<button class="btn-dl" data-url="' + safeUrlAttr + '" onclick="addDownload(this.dataset.url)">&#8659; Descargar</button>'
          + '<button class="btn-night" data-url="' + safeUrlAttr + '" onclick="addNight(this.dataset.url)">&#x1F319; Esta noche</button>'
          + '</div>'
          + '</div>';
      }}).join('');
    }} catch(ex) {{
      statusEl.textContent = 'Error al buscar.';
    }}
  }}

  async function addDownload(url) {{
    const fd = new FormData();
    fd.append('url', url);
    fd.append('subfolder', 'Descargas');
    try {{
      await fetch('/add', {{method:'POST', body: fd}});
      alert('Añadido a la cola: ' + url.slice(0,60));
    }} catch(ex) {{
      alert('Error de red');
    }}
  }}

  // ── Cola nocturna ─────────────────────────────────────────────────
  let nightItems = {nq_json};

  function renderNightQueue() {{
    const listEl  = document.getElementById('nq-list');
    const countEl = document.getElementById('nq-count');
    countEl.textContent = nightItems.length;
    if (!nightItems.length) {{
      listEl.innerHTML = '<p class="muted">Sin elementos.</p>';
      return;
    }}
    listEl.innerHTML = nightItems.map(function(item, idx) {{
      return '<div class="nq-item">'
        + '<span class="nq-url">' + escHtml(item.url.slice(0,70)) + '</span>'
        + '<button class="btn-sm" style="color:#f87171" onclick="removeNight(' + idx + ')">&#x2715;</button>'
        + '</div>';
    }}).join('');
  }}

  async function addNight(url) {{
    const fd = new FormData();
    fd.append('url', url);
    fd.append('subfolder', 'Descargas');
    try {{
      const r   = await fetch('/schedule', {{method:'POST', body: fd}});
      const res = await r.json();
      if (res.ok) {{
        nightItems = res.queue;
        renderNightQueue();
      }}
    }} catch(ex) {{
      alert('Error de red');
    }}
  }}

  async function removeNight(idx) {{
    const item = nightItems[idx];
    if (!item) return;
    const fd = new FormData();
    fd.append('url', item.url);
    try {{
      const r   = await fetch('/unschedule', {{method:'POST', body: fd}});
      const res = await r.json();
      if (res.ok) {{
        nightItems = res.queue;
        renderNightQueue();
      }}
    }} catch(ex) {{
      alert('Error de red');
    }}
  }}

  renderNightQueue();

  // ── Importar Spotify ──────────────────────────────────────────────
  async function importSpotify() {{
    const url = document.getElementById('spotify-url').value.trim();
    if (!url) return;
    const statusEl = document.getElementById('spotify-status');
    const listEl   = document.getElementById('spotify-list');
    statusEl.textContent = 'Contactando Spotify…';
    listEl.innerHTML = '';
    const fd = new FormData();
    fd.append('url', url);
    try {{
      const r   = await fetch('/spotify', {{method:'POST', body: fd}});
      const res = await r.json();
      if (res.ok) {{
        statusEl.textContent = res.count + ' canciones añadidas a la cola.';
        listEl.innerHTML = res.tracks.map(function(t) {{
          return '<div style="padding:3px 0;border-bottom:1px solid #3f3f46">'
            + escHtml(t.artist) + ' — ' + escHtml(t.title) + '</div>';
        }}).join('');
      }} else {{
        statusEl.textContent = 'Error: ' + (res.error || 'desconocido');
      }}
    }} catch(ex) {{
      statusEl.textContent = 'Error de red.';
    }}
  }}

  // ── Biblioteca agrupada ───────────────────────────────────────────
  let libLoaded = false;
  const _artistImgTs = {{}};
  async function loadLibrary() {{
    const loadEl = document.getElementById('lib-loading');
    const listEl = document.getElementById('lib-list');
    loadEl.textContent = 'Cargando…';
    loadEl.style.display = '';
    listEl.style.opacity = '0.4';
    let songs;
    try {{
      const r = await fetch('/api/library');
      songs = await r.json();
    }} catch(e) {{
      loadEl.textContent = 'Error al cargar la biblioteca.';
      listEl.style.opacity = '';
      return;
    }}
    loadEl.style.display = 'none';
    listEl.style.opacity = '';
    libLoaded = true;
    if (!songs.length) {{
      document.getElementById('lib-list').innerHTML = '<p class="muted">Sin canciones todavía.</p>';
      return;
    }}

    // Agrupar por artista → album
    const byArtist = {{}};
    for (let i = 0; i < songs.length; i++) {{
      const s  = songs[i];
      const ar = s.ar || '(Sin artista)';
      const al = s.al || '(Sin álbum)';
      if (!byArtist[ar]) byArtist[ar] = {{}};
      if (!byArtist[ar][al]) byArtist[ar][al] = [];
      byArtist[ar][al].push(s);
    }}

    let html2 = '';
    const artists = Object.keys(byArtist).sort();
    for (let ai = 0; ai < artists.length; ai++) {{
      const ar      = artists[ai];
      const albums  = byArtist[ar];
      const arId    = 'ar-' + ai;
      const arCount = Object.values(albums).reduce(function(acc, a) {{ return acc + a.length; }}, 0);
      html2 += '<div class="artist-section">';
      html2 += '<div class="artist-header" data-sec="' + arId + '" onclick="toggleSection(this.dataset.sec)">'
             + '<span class="collapse-icon" id="' + arId + '-icon">&#9660;</span>'
             + '<img class="artist-thumb" loading="lazy" src="/artist-cover?artist=' + encodeURIComponent(ar) + (_artistImgTs[ar] ? '&_=' + _artistImgTs[ar] : '') + '" alt="" onerror="this.style.opacity=0">'
             + '<span>' + escHtml(ar) + '</span>'
             + '<span class="muted" style="font-size:.8rem;margin-left:auto">' + arCount + ' canciones</span>'
             + '<button class="btn-sm" data-artist="' + escHtml(ar) + '" onclick="event.stopPropagation();pickArtistImg(this.dataset.artist)" style="margin-left:8px;padding:4px 8px;flex-shrink:0" title="Cambiar imagen">🖼</button>'
             + '</div>';
      html2 += '<div id="' + arId + '">';
      const albumNames = Object.keys(albums).sort();
      for (let li = 0; li < albumNames.length; li++) {{
        const al    = albumNames[li];
        const slist = albums[al];
        const alId  = arId + '-al-' + li;
        html2 += '<div class="album-section">';
        html2 += '<div class="album-header" data-sec="' + alId + '" onclick="toggleSection(this.dataset.sec)">'
               + '<span class="collapse-icon" id="' + alId + '-icon">&#9660;</span>'
               + '<span>' + escHtml(al) + '</span>'
               + '<span class="muted" style="font-size:.78rem;margin-left:auto">' + slist.length + '</span>'
               + '</div>';
        html2 += '<div id="' + alId + '">';
        for (let si = 0; si < slist.length; si++) {{
          const s = slist[si];
          const searchVal = escHtml((s.t + ' ' + s.ar + ' ' + s.al).toLowerCase());
          html2 += '<div class="song-row" data-search="' + searchVal + '" onclick="rowClick(event,this)">'
                 + '<input type="checkbox" class="song-check" data-p="' + escHtml(s.p) + '" onchange="updateBulkBar()" style="flex-shrink:0;accent-color:#f59e0b;width:16px;height:16px">'
                 + '<img src="/cover?p=' + encodeURIComponent(s.p) + '" alt="" style="width:36px;height:36px;object-fit:cover;border-radius:4px;background:#3f3f46;flex-shrink:0" onerror="this.style.background=&quot;#3f3f46&quot;;this.src=&quot;&quot;">'
                 + '<div style="flex:1;min-width:0">'
                 + '<div style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + escHtml(s.t) + '</div>'
                 + '<div class="muted" style="font-size:.78rem">' + s.sz + '</div>'
                 + '</div>'
                 + '<button class="btn-sm" style="padding:5px 8px" data-p="' + escHtml(s.p) + '" data-t="' + escHtml(s.t) + '" data-ar="' + escHtml(s.ar) + '" onclick="playSong(this.dataset.p,this.dataset.t,this.dataset.ar,this.dataset.p)">&#9654;</button>'
                 + '<button class="btn-sm" style="padding:5px 8px" data-p="' + escHtml(s.p) + '" data-t="' + escHtml(s.t) + '" data-ar="' + escHtml(s.ar) + '" data-al="' + escHtml(s.al) + '" data-ge="' + escHtml(s.ge) + '" onclick="openEdit(this.dataset.p,this.dataset.t,this.dataset.ar,this.dataset.al,this.dataset.ge)">&#9998;</button>'
                 + '<button class="btn-sm" style="padding:5px 8px;color:#f87171" data-p="' + escHtml(s.p) + '" data-t="' + escHtml(s.t) + '" onclick="deleteSong(this.dataset.p,this.dataset.t)">&#128465;</button>'
                 + '</div>';
        }}
        html2 += '</div></div>';
      }}
      html2 += '</div></div>';
    }}
    document.getElementById('lib-list').innerHTML = html2;
  }}

  function toggleSection(id) {{
    const el   = document.getElementById(id);
    const icon = document.getElementById(id + '-icon');
    if (!el) return;
    const hidden = el.style.display === 'none';
    el.style.display = hidden ? '' : 'none';
    if (icon) icon.style.transform = hidden ? '' : 'rotate(-90deg)';
  }}

  // ── Filtrar biblioteca ────────────────────────────────────────────
  function filterLibrary(q) {{
    q = q.toLowerCase();
    document.querySelectorAll('.artist-section').forEach(function(sec) {{
      let artistMatch = false;
      sec.querySelectorAll('.album-section').forEach(function(alSec) {{
        let albumMatch = false;
        alSec.querySelectorAll('.song-row').forEach(function(row) {{
          const match = !q || (row.dataset.search || '').includes(q);
          row.style.display = match ? '' : 'none';
          if (match) albumMatch = true;
        }});
        alSec.style.display = albumMatch ? '' : 'none';
        if (albumMatch) artistMatch = true;
      }});
      sec.style.display = artistMatch ? '' : 'none';
    }});
  }}

  // ── Duplicados ────────────────────────────────────────────────────
  async function findDuplicates() {{
    const statusEl = document.getElementById('dup-status');
    const listEl   = document.getElementById('dup-list');
    statusEl.textContent = 'Buscando duplicados…';
    listEl.innerHTML     = '';
    try {{
      const r     = await fetch('/api/duplicates');
      const groups = await r.json();
      if (!groups.length) {{
        statusEl.textContent = 'No se encontraron duplicados.';
        return;
      }}
      statusEl.textContent = groups.length + ' grupo(s) con duplicados';
      listEl.innerHTML = groups.map(function(group) {{
        const rows = group.map(function(f) {{
          return '<div style="display:flex;align-items:center;gap:8px;padding:6px 0;border-bottom:1px solid #3f3f46">'
            + '<div style="flex:1;min-width:0">'
            + '<div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + escHtml(f.t) + '</div>'
            + '<div class="muted" style="font-size:.78rem">' + escHtml(f.r) + ' &middot; ' + f.sz + '</div>'
            + '</div>'
            + '<button class="btn-sm" style="color:#f87171" data-p="' + escHtml(f.p) + '" data-t="' + escHtml(f.t) + '" onclick="deleteSong(this.dataset.p,this.dataset.t)">&#128465;</button>'
            + '</div>';
        }}).join('');
        return '<div style="background:#1e1e20;border-radius:8px;padding:10px;margin:8px 0">'
          + '<div style="color:#fbbf24;font-size:.85rem;font-weight:600;margin-bottom:6px">'
          + escHtml(group[0].ar || '(Sin artista)') + ' — ' + escHtml(group[0].t)
          + '</div>'
          + rows
          + '</div>';
      }}).join('');
    }} catch(ex) {{
      statusEl.textContent = 'Error al buscar duplicados.';
    }}
  }}

  // ── Estadísticas ──────────────────────────────────────────────────
  async function loadStats() {{
    const el = document.getElementById('stats-wrap');
    el.textContent = 'Calculando…';
    try {{
      const r = await fetch('/api/stats');
      const s = await r.json();
      const pct = function(n) {{ return s.songs ? Math.round(n / s.songs * 100) + '%' : '—'; }};
      el.innerHTML =
        '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px;margin-top:4px">'
        + stat('🎵', s.songs, 'canciones')
        + stat('🎤', s.artists, 'artistas')
        + stat('💿', s.albums, 'álbumes')
        + stat('⏱', s.duration, '')
        + stat('💾', s.size_gb + ' GB', '')
        + stat('🖼', pct(s.with_cover), 'con portada')
        + stat('📝', pct(s.with_lyrics), 'con letra')
        + '</div>';
    }} catch(ex) {{
      el.textContent = 'Error al calcular estadísticas.';
    }}
  }}

  function stat(icon, val, label) {{
    return '<div style="background:#3f3f46;border-radius:8px;padding:10px;text-align:center">'
      + '<div style="font-size:1.4rem">' + icon + '</div>'
      + '<div style="font-weight:700;font-size:1.1rem;color:#f59e0b">' + val + '</div>'
      + (label ? '<div class="muted" style="font-size:.72rem">' + escHtml(label) + '</div>' : '')
      + '</div>';
  }}

  // ── Editar tags ───────────────────────────────────────────────────
  function openEdit(pathB64, title, artist, album, genre) {{
    document.getElementById('edit-path').value = pathB64;
    document.getElementById('edit-title').value = title;
    document.getElementById('edit-artist').value = artist;
    document.getElementById('edit-album').value = album;
    document.getElementById('edit-genre').value = genre || '';
    document.getElementById('edit-error').style.display = 'none';
    document.getElementById('edit-cover-input').value = '';
    const img = document.getElementById('edit-cover-preview');
    img.src = '/cover?p=' + encodeURIComponent(pathB64) + '&_=' + Date.now();
    img.style.display = 'block';
    document.getElementById('edit-modal').style.display = 'flex';
  }}

  function closeModal() {{
    document.getElementById('edit-modal').style.display = 'none';
  }}

  function previewCover(input) {{
    if (!input.files[0]) return;
    const reader = new FileReader();
    reader.onload = function(e) {{
      document.getElementById('edit-cover-preview').src = e.target.result;
    }};
    reader.readAsDataURL(input.files[0]);
  }}

  async function saveEdit() {{
    const fd = new FormData();
    fd.append('path',   document.getElementById('edit-path').value);
    fd.append('title',  document.getElementById('edit-title').value);
    fd.append('artist', document.getElementById('edit-artist').value);
    fd.append('album',  document.getElementById('edit-album').value);
    fd.append('genre',  document.getElementById('edit-genre').value);
    const coverFile = document.getElementById('edit-cover-input').files[0];
    if (coverFile) fd.append('cover', coverFile);
    const errEl = document.getElementById('edit-error');
    errEl.style.display = 'none';
    try {{
      const r   = await fetch('/edit', {{method:'POST', body: fd}});
      const res = await r.json();
      if (res.ok) {{ closeModal(); libLoaded = false; loadLibrary(); }}
      else {{ errEl.textContent = res.error || 'Error desconocido'; errEl.style.display='block'; }}
    }} catch(e) {{
      errEl.textContent = 'Error de red'; errEl.style.display = 'block';
    }}
  }}

  // ── Eliminar canción ─────────────────────────────────────────────
  async function deleteSong(pathB64, title) {{
    if (!confirm('\\u00bfEliminar "' + title + '"?\\nEsta acci\\u00f3n no se puede deshacer.')) return;
    const fd = new FormData();
    fd.append('path', pathB64);
    try {{
      const r   = await fetch('/delete', {{method:'POST', body: fd}});
      const res = await r.json();
      if (res.ok) {{ libLoaded = false; loadLibrary(); }}
      else alert('Error: ' + (res.error || 'desconocido'));
    }} catch(e) {{
      alert('Error de red');
    }}
  }}

  // ── Mini player ───────────────────────────────────────────────────
  const audio  = document.getElementById('pl-audio');
  const player = document.getElementById('player');

  function playSong(pathB64, title, artist, coverB64) {{
    document.getElementById('pl-title').textContent = title || '';
    document.getElementById('pl-artist').textContent = artist || '';
    document.getElementById('pl-cover').src = '/cover?p=' + encodeURIComponent(coverB64 || pathB64);
    audio.src = '/stream?p=' + encodeURIComponent(pathB64);
    player.style.display = 'flex';
    audio.play();
    document.getElementById('pl-btn').textContent = '⏸';
    document.body.style.paddingBottom = '80px';
  }}

  function togglePlay() {{
    if (audio.paused) {{
      audio.play();
      document.getElementById('pl-btn').textContent = '⏸';
    }} else {{
      audio.pause();
      document.getElementById('pl-btn').textContent = '▶';
    }}
  }}

  function closePlayer() {{
    audio.pause();
    player.style.display = 'none';
    document.body.style.paddingBottom = '';
  }}

  audio.addEventListener('timeupdate', function() {{
    if (!audio.duration) return;
    document.getElementById('pl-seek').value = (audio.currentTime / audio.duration) * 100;
    const m = Math.floor(audio.currentTime / 60);
    const s = Math.floor(audio.currentTime % 60).toString().padStart(2, '0');
    document.getElementById('pl-time').textContent = m + ':' + s;
  }});

  audio.addEventListener('ended', function() {{
    document.getElementById('pl-btn').textContent = '▶';
  }});

  document.getElementById('pl-seek').addEventListener('input', function() {{
    if (audio.duration) audio.currentTime = (this.value / 100) * audio.duration;
  }});

  // ── Drag & drop ──────────────────────────────────────────────────
  const dz = document.getElementById('dropzone');
  dz.addEventListener('dragover', function(e) {{ e.preventDefault(); dz.classList.add('drag'); }});
  dz.addEventListener('dragleave', function() {{ dz.classList.remove('drag'); }});
  dz.addEventListener('drop', function(e) {{
    e.preventDefault(); dz.classList.remove('drag');
    document.getElementById('file-input').files = e.dataTransfer.files;
    showFiles(e.dataTransfer.files);
  }});
  document.getElementById('file-input').addEventListener('change', function() {{
    showFiles(this.files);
  }});

  function fmtSize(b) {{
    if (b < 1024) return b + ' B';
    if (b < 1048576) return (b/1024).toFixed(1) + ' KB';
    return (b/1048576).toFixed(1) + ' MB';
  }}

  function showFiles(files) {{
    const list = document.getElementById('file-list');
    list.innerHTML = '';
    for (let i = 0; i < files.length; i++) {{
      const f   = files[i];
      const div = document.createElement('div');
      div.className = 'file-item';
      div.innerHTML = '<span class="fname">' + escHtml(f.name) + '</span>'
                    + '<span class="fsize">' + fmtSize(f.size) + '</span>';
      list.appendChild(div);
    }}
  }}

  function escHtml(s) {{
    return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }}

  // ── Upload ───────────────────────────────────────────────────────
  function startUpload() {{
    const input = document.getElementById('file-input');
    if (!input.files.length) {{ alert('Elige al menos un archivo.'); return; }}

    const subfolder = document.getElementById('subfolder-upload').value || 'Subidas';
    const fd = new FormData();
    fd.append('subfolder', subfolder);
    for (let i = 0; i < input.files.length; i++) fd.append('files', input.files[i]);

    document.getElementById('progress-wrap').style.display = 'block';
    document.getElementById('btn-upload').disabled = true;

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/upload');

    xhr.upload.onprogress = function(e) {{
      if (e.lengthComputable) {{
        const pct = Math.round(e.loaded / e.total * 100);
        document.getElementById('progress-bar').style.width = pct + '%';
        document.getElementById('progress-label').textContent = pct + '%  ('
          + fmtSize(e.loaded) + ' / ' + fmtSize(e.total) + ')';
      }}
    }};

    xhr.onload = function() {{
      document.getElementById('btn-upload').disabled = false;
      if (xhr.status === 200) {{
        const res = JSON.parse(xhr.responseText);
        document.getElementById('progress-label').textContent =
          res.ok + ' archivo(s) subido(s). ' + (res.errors.length ? 'Errores: ' + res.errors.join(', ') : '');
        document.getElementById('progress-bar').style.width = '100%';
        document.getElementById('file-list').innerHTML = '';
        input.value = '';
        setTimeout(function() {{ location.reload(); }}, 1500);
      }} else {{
        document.getElementById('progress-label').textContent = 'Error: ' + xhr.responseText;
      }}
    }};

    xhr.onerror = function() {{
      document.getElementById('btn-upload').disabled = false;
      document.getElementById('progress-label').textContent = 'Error de red.';
    }};

    xhr.send(fd);
  }}

  // ── Multi-selección ────────────────────────────────────────────────
  function rowClick(event, row) {{
    if (event.target.tagName === 'BUTTON' || event.target.tagName === 'INPUT') return;
    const c = row.querySelector('.song-check');
    if (c) {{ c.checked = !c.checked; updateBulkBar(); }}
  }}

  function updateBulkBar() {{
    const checked = document.querySelectorAll('.song-check:checked');
    const bar = document.getElementById('bulk-bar');
    document.getElementById('bulk-count').textContent = checked.length + ' seleccionada' + (checked.length !== 1 ? 's' : '');
    bar.style.display = checked.length ? 'flex' : 'none';
  }}

  function clearSelection() {{
    document.querySelectorAll('.song-check:checked').forEach(function(c) {{ c.checked = false; }});
    document.getElementById('bulk-bar').style.display = 'none';
  }}

  async function bulkDelete() {{
    const checked = Array.from(document.querySelectorAll('.song-check:checked'));
    if (!checked.length) return;
    if (!confirm('\\u00bfEliminar ' + checked.length + ' canciones?\\nEsta acci\\u00f3n no se puede deshacer.')) return;
    let errors = 0;
    for (let i = 0; i < checked.length; i++) {{
      const fd = new FormData();
      fd.append('path', checked[i].dataset.p);
      try {{
        const r   = await fetch('/delete', {{method:'POST', body: fd}});
        const res = await r.json();
        if (!res.ok) errors++;
      }} catch(ex) {{ errors++; }}
    }}
    libLoaded = false;
    loadLibrary();
    if (errors) alert(errors + ' error(es) al eliminar.');
  }}

  // ── Escáner de calidad ────────────────────────────────────────────
  async function runQualityScan() {{
    const statusEl = document.getElementById('quality-status');
    const listEl   = document.getElementById('quality-list');
    statusEl.textContent = 'Escaneando… (puede tardar unos segundos)';
    listEl.innerHTML = '';
    try {{
      const r      = await fetch('/api/quality');
      const issues = await r.json();
      if (!issues.length) {{
        statusEl.textContent = '✓ Todo en orden. No hay canciones con datos incompletos.';
        return;
      }}
      statusEl.textContent = issues.length + ' canción(es) con datos incompletos:';
      listEl.innerHTML = issues.map(function(s) {{
        return '<div style="display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid #3f3f46">'
          + '<div style="flex:1;min-width:0">'
          + '<div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:.88rem">'
          + escHtml(s.t || s.f) + (s.ar ? ' <span class="muted">— ' + escHtml(s.ar) + '</span>' : '') + '</div>'
          + '<div style="margin-top:3px">' + s.missing.map(function(m) {{
              return '<span style="background:#450a0a;color:#f87171;border-radius:4px;padding:1px 6px;font-size:.72rem;margin-right:4px">' + escHtml(m) + '</span>';
            }}).join('') + '</div>'
          + '</div>'
          + '<button class="btn-sm" data-p="' + escHtml(s.p) + '" data-t="' + escHtml(s.t) + '" data-ar="' + escHtml(s.ar) + '" data-al="" data-ge="" onclick="openEdit(this.dataset.p,this.dataset.t,this.dataset.ar,this.dataset.al,this.dataset.ge)" style="flex-shrink:0">✎ Editar</button>'
          + '</div>';
      }}).join('');
    }} catch(ex) {{
      statusEl.textContent = 'Error al escanear.';
    }}
  }}

  // ── Imagen de artista ─────────────────────────────────────────────
  function pickArtistImg(artist) {{
    const inp = document.createElement('input');
    inp.type = 'file';
    inp.accept = 'image/*';
    inp.onchange = function() {{
      if (!inp.files[0]) return;
      const fd = new FormData();
      fd.append('artist', artist);
      fd.append('image', inp.files[0]);
      fetch('/artist-cover', {{method: 'POST', body: fd}})
        .then(function(r) {{ return r.json(); }})
        .then(function(res) {{
          if (res.ok) {{
            const ts = Date.now();
            _artistImgTs[artist] = ts;
            document.querySelectorAll('img.artist-thumb').forEach(function(img) {{
              try {{
                const u = new URL(img.src, location.href);
                if (decodeURIComponent(u.searchParams.get('artist')) === artist) {{
                  u.searchParams.set('_', ts);
                  img.style.opacity = '';
                  img.src = u.href;
                }}
              }} catch(e) {{}}
            }});
            libLoaded = false;
            loadLibrary();
          }} else {{
            alert('Error: ' + (res.error || 'desconocido'));
          }}
        }})
        .catch(function() {{ alert('Error de red'); }});
    }};
    inp.click();
  }}

  // ── yt-dlp actualizar ─────────────────────────────────────────────
  async function updateYtdlp() {{
    const btn   = document.getElementById('btn-ytdlp-update');
    const logEl = document.getElementById('ytdlp-log');
    const verEl = document.getElementById('ytdlp-ver');
    btn.disabled = true;
    btn.textContent = 'Actualizando…';
    logEl.style.display = 'block';
    logEl.textContent = 'Ejecutando yt-dlp -U …';
    try {{
      const r   = await fetch('/ytdlp-update', {{method:'POST'}});
      const res = await r.json();
      logEl.textContent = res.output || '(sin salida)';
      if (res.version) verEl.textContent = res.version;
    }} catch(ex) {{
      logEl.textContent = 'Error de red.';
    }}
    btn.disabled = false;
    btn.textContent = '↑ Actualizar';
  }}

  // ── Reproduciendo ahora ────────────────────────────────────────────
  async function pollNowPlaying() {{
    try {{
      const r   = await fetch('/api/nowplaying');
      const np  = await r.json();
      const card = document.getElementById('np-card');
      if (!card) return;
      if (np && np.title) {{
        document.getElementById('np-title').textContent  = np.title;
        document.getElementById('np-artist').textContent = np.artist || '';
        document.getElementById('np-cover').src = np.coverArt
          ? '{nd_url_js}/rest/getCoverArt.view?u={nd_user_js}&p={nd_pass_js}&v=1.16.1&c=webqueue&id=' + encodeURIComponent(np.coverArt)
          : '';
        card.style.display = 'flex';
      }} else {{
        card.style.display = 'none';
      }}
    }} catch(ex) {{}}
  }}
  pollNowPlaying();
  setInterval(pollNowPlaying, 15000);

  // Cargar biblioteca al abrir la página (pestaña Biblioteca siempre lista)
  loadLibrary();
  </script>
</body>
</html>'''


# ── Handler HTTP ───────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _html(self, body, code=200):
        data = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', len(data))
        self.end_headers()
        self.wfile.write(data)

    def _json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(data))
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, loc, flash='', ok=True):
        param = f'?flash={urllib.parse.quote(flash)}&ok={"1" if ok else "0"}' if flash else ''
        self.send_response(303)
        self.send_header('Location', loc + param)
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        qs     = urllib.parse.parse_qs(parsed.query)

        if parsed.path == '/manifest.json':
            data = _MANIFEST.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/manifest+json')
            self.send_header('Content-Length', len(data))
            self.end_headers()
            self.wfile.write(data)
        elif parsed.path == '/icon.png':
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', len(_ICON_PNG))
            self.send_header('Cache-Control', 'max-age=86400')
            self.end_headers()
            self.wfile.write(_ICON_PNG)
        elif parsed.path == '/api/library':
            self._json(_list_songs())
        elif parsed.path == '/api/search':
            q = unquote_plus(qs.get('q', [''])[0]).strip()
            if not q:
                self._json([])
            else:
                self._json(_yt_search(q))
        elif parsed.path == '/api/duplicates':
            self._json(_find_duplicates())
        elif parsed.path == '/api/nightqueue':
            with night_lock:
                self._json(list(night_queue))
        elif parsed.path == '/api/stats':
            self._json(_get_library_stats())
        elif parsed.path == '/api/quality':
            self._json(_scan_quality())
        elif parsed.path == '/api/nowplaying':
            self._json(_now_playing() or {})
        elif parsed.path == '/events':
            self._handle_sse()
        elif parsed.path == '/cover':
            self._handle_cover(qs)
        elif parsed.path == '/artist-cover':
            self._handle_artist_cover_get(qs)
        elif parsed.path == '/stream':
            self._handle_stream(qs)
        else:
            flash = unquote_plus(qs.get('flash', [''])[0])
            ok    = qs.get('ok', ['1'])[0] == '1'
            self._html(render_page(flash, ok))

    def do_POST(self):
        path = urlparse(self.path).path

        if path == '/add':
            self._handle_add()
        elif path == '/upload':
            self._handle_upload()
        elif path == '/scan':
            self._handle_scan()
        elif path == '/edit':
            self._handle_edit()
        elif path == '/delete':
            self._handle_delete()
        elif path == '/schedule':
            self._handle_schedule()
        elif path == '/unschedule':
            self._handle_unschedule()
        elif path == '/spotify':
            self._handle_spotify()
        elif path == '/ytdlp-update':
            self._handle_ytdlp_update()
        elif path == '/artist-cover':
            self._handle_artist_cover_post()
        else:
            self._html('<p>Not found</p>', 404)

    def _handle_add(self):
        content_type = self.headers.get('Content-Type', '')
        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length)

        # Support both multipart/form-data and application/x-www-form-urlencoded
        if 'multipart' in content_type:
            m = re.search(r'boundary=([^\s;]+)', content_type)
            params = {}
            if m:
                boundary = ('--' + m.group(1).strip('"')).encode()
                for part in body.split(boundary)[1:]:
                    if part.startswith(b'--'):
                        continue
                    if part.startswith(b'\r\n'):
                        part = part[2:]
                    if b'\r\n\r\n' not in part:
                        continue
                    hdr, val = part.split(b'\r\n\r\n', 1)
                    nm = re.search(rb'name="([^"]*)"', hdr)
                    if nm:
                        params[nm.group(1).decode()] = val.strip().rstrip(b'\r\n').decode('utf-8', errors='replace')
        else:
            params = {k: unquote_plus(v) for k, v in
                      (p.split('=', 1) for p in body.decode('utf-8', errors='replace').split('&') if '=' in p)}

        url       = params.get('url', '').strip()
        subfolder = (params.get('subfolder', '') or 'Descargas').strip()
        if not url:
            self._redirect('/', 'URL vacía', ok=False)
            return
        job = {
            'url': url, 'dest': os.path.join(MUSIC_DIR, subfolder),
            'status': 'queued', 'started': '', 'finished': '', 'log': [],
            'added': datetime.now().strftime('%H:%M:%S'),
        }
        download_queue.put(job)
        # If request was JSON-like (from JS fetch), return JSON; else redirect
        accept = self.headers.get('Accept', '')
        if 'application/json' in accept:
            self._json({'ok': True})
        else:
            self._redirect('/', f'Añadido a la cola: {url[:50]}')

    def _handle_upload(self):
        content_type = self.headers.get('Content-Type', '')
        length = int(self.headers.get('Content-Length', 0))

        if length > MAX_UPLOAD_BYTES:
            self._json({'error': f'Demasiado grande (máx {MAX_UPLOAD_BYTES//1024//1024} MB)'}, 413)
            return

        try:
            ok_files, last_dest, errors = _stream_upload(
                self.rfile, content_type, length, MUSIC_DIR)
        except Exception as e:
            self._json({'ok': 0, 'errors': [f'Error interno: {e}']}, 500)
            return

        ok_count = len(ok_files)
        if ok_count:
            _notify(f'{ok_count} archivo(s) subido(s)')
            threading.Thread(target=_post_upload, args=(last_dest,), daemon=True).start()

        self._json({'ok': ok_count, 'errors': errors})

    def _handle_scan(self):
        success, msg = _trigger_scan()
        self._redirect('/', msg, ok=success)

    def _handle_cover(self, qs):
        b64  = unquote_plus(qs.get('p', [''])[0])
        path = _safe_path(b64)
        if not path or not os.path.isfile(path):
            self.send_response(404); self.end_headers(); return
        data, mime = _get_cover_bytes(path)
        if not data:
            self.send_response(204); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', len(data))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def _handle_artist_cover_get(self, qs):
        artist = unquote_plus(qs.get('artist', [''])[0]).strip()
        if not artist:
            self.send_response(204); self.end_headers(); return
        data, mime = _get_artist_cover(artist)
        if not data:
            self.send_response(204); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', len(data))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def _handle_artist_cover_post(self):
        content_type = self.headers.get('Content-Type', '')
        length = int(self.headers.get('Content-Length', 0))
        if length > 20 * 1024 * 1024:
            self._json({'ok': False, 'error': 'Imagen demasiado grande (máx 20 MB)'}); return
        body = b''
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk: break
            body += chunk
            remaining -= len(chunk)
        m = re.search(r'boundary=([^\s;]+)', content_type)
        if not m:
            self._json({'ok': False, 'error': 'Content-Type inválido'}); return
        boundary = ('--' + m.group(1).strip('"')).encode()
        artist_name = None
        image_data  = None
        image_ext   = '.jpg'
        for part in body.split(boundary)[1:]:
            if part.startswith(b'--') or part in (b'\r\n', b''):
                continue
            if part.startswith(b'\r\n'): part = part[2:]
            if part.endswith(b'\r\n'):   part = part[:-2]
            if b'\r\n\r\n' not in part:  continue
            raw_hdrs, content = part.split(b'\r\n\r\n', 1)
            hdrs = {}
            for line in raw_hdrs.decode('utf-8', errors='replace').split('\r\n'):
                if ':' in line:
                    k, v = line.split(':', 1)
                    hdrs[k.strip().lower()] = v.strip()
            cd = hdrs.get('content-disposition', '')
            nm = re.search(r'name="([^"]*)"', cd)
            fm = re.search(r'filename="([^"]*)"', cd)
            if not nm: continue
            if nm.group(1) == 'artist':
                artist_name = content.decode('utf-8', errors='replace').strip()
            elif nm.group(1) == 'image' and fm:
                image_data = content
                ext = Path(fm.group(1)).suffix.lower()
                image_ext = ext if ext in ('.jpg', '.jpeg', '.png') else '.jpg'
        if not artist_name or not image_data:
            self._json({'ok': False, 'error': 'Faltan datos (artist + image)'}); return
        folder = _get_artist_folder(artist_name)
        if not folder:
            self._json({'ok': False, 'error': f'No se encontró carpeta para "{artist_name}"'}); return
        save_name = 'artist.png' if image_ext == '.png' else 'artist.jpg'
        save_path  = os.path.join(folder, save_name)
        try:
            with open(save_path, 'wb') as f:
                f.write(image_data)
            # Invalidate cache
            global _artist_folder_cache
            _artist_folder_cache = {}
            threading.Thread(target=_trigger_scan, daemon=True).start()
            self._json({'ok': True, 'path': save_path})
        except Exception as e:
            self._json({'ok': False, 'error': str(e)})

    def _handle_stream(self, qs):
        """Sirve un archivo de audio con soporte de Range (HTTP 206)."""
        MIME_MAP = {
            '.mp3':  'audio/mpeg',
            '.flac': 'audio/flac',
            '.m4a':  'audio/mp4',
            '.ogg':  'audio/ogg',
            '.opus': 'audio/ogg',
            '.wav':  'audio/wav',
            '.aac':  'audio/aac',
        }
        b64  = unquote_plus(qs.get('p', [''])[0])
        path = _safe_path(b64)
        if not path or not os.path.isfile(path):
            self.send_response(404); self.end_headers(); return

        ext       = Path(path).suffix.lower()
        mime      = MIME_MAP.get(ext, 'application/octet-stream')
        file_size = os.path.getsize(path)

        range_hdr = self.headers.get('Range', '')
        try:
            if range_hdr:
                m = re.match(r'bytes=(\d*)-(\d*)', range_hdr)
                if m:
                    start = int(m.group(1)) if m.group(1) else 0
                    end   = int(m.group(2)) if m.group(2) else file_size - 1
                else:
                    start, end = 0, file_size - 1
                end = min(end, file_size - 1)
                length = end - start + 1
                self.send_response(206)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', length)
                self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                with open(path, 'rb') as fh:
                    fh.seek(start)
                    remaining = length
                    while remaining > 0:
                        chunk = fh.read(min(65536, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            else:
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', file_size)
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                with open(path, 'rb') as fh:
                    while True:
                        chunk = fh.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def _handle_sse(self):
        """Server-Sent Events: envía estado cada segundo."""
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.send_header('X-Accel-Buffering', 'no')
        self.end_headers()

        last_log_len = 0
        try:
            while True:
                with state_lock:
                    job     = dict(current_job) if current_job else None
                    log_now = list(current_log)
                    q_size  = download_queue.qsize()

                new_lines = log_now[last_log_len:]
                last_log_len = len(log_now)

                payload = json.dumps({
                    'job': job,
                    'log': new_lines,
                    'q':   q_size,
                })
                msg = f'data: {payload}\n\n'
                self.wfile.write(msg.encode('utf-8'))
                self.wfile.flush()
                time.sleep(1)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def _handle_edit(self):
        content_type = self.headers.get('Content-Type', '')
        length       = int(self.headers.get('Content-Length', 0))

        if length > 20 * 1024 * 1024:
            self._json({'ok': False, 'error': 'Payload demasiado grande (máx 20 MB)'}); return

        # Leer todo en memoria — el edit es pequeño (texto + portada)
        body = b''
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk: break
            body += chunk
            remaining -= len(chunk)

        m = re.search(r'boundary=([^\s;]+)', content_type)
        if not m:
            self._json({'ok': False, 'error': 'Content-Type inválido'}); return

        boundary   = ('--' + m.group(1).strip('"')).encode()
        fields     = {}
        cover_data = None

        for part in body.split(boundary)[1:]:
            if part.startswith(b'--') or part in (b'\r\n', b''):
                continue
            if part.startswith(b'\r\n'): part = part[2:]
            if part.endswith(b'\r\n'):   part = part[:-2]
            if b'\r\n\r\n' not in part:  continue

            raw_hdrs, content = part.split(b'\r\n\r\n', 1)
            hdrs = {}
            for line in raw_hdrs.decode('utf-8', errors='replace').split('\r\n'):
                if ':' in line:
                    k, v = line.split(':', 1)
                    hdrs[k.strip().lower()] = v.strip()

            cd = hdrs.get('content-disposition', '')
            nm = re.search(r'name="([^"]*)"', cd)
            fm = re.search(r'filename="([^"]*)"', cd)
            if not nm: continue

            if fm:
                cover_data = content
            else:
                fields[nm.group(1)] = content.decode('utf-8', errors='replace')

        path = _safe_path(fields.get('path', ''))
        if not path or not os.path.isfile(path):
            self._json({'ok': False, 'error': 'Archivo no encontrado'}); return

        ok, err = _write_tags(
            path,
            fields.get('title'),
            fields.get('artist'),
            fields.get('album'),
            fields.get('genre'),
            cover_data or None,
        )
        if ok:
            threading.Thread(target=_trigger_scan, daemon=True).start()
            self._json({'ok': True})
        else:
            self._json({'ok': False, 'error': err})

    def _handle_delete(self):
        content_type = self.headers.get('Content-Type', '')
        length       = int(self.headers.get('Content-Length', 0))
        body         = self.rfile.read(length)

        # Parsear como multipart o form-urlencoded
        b64 = ''
        if 'multipart' in content_type:
            m = re.search(r'boundary=([^\s;]+)', content_type)
            if m:
                boundary = ('--' + m.group(1).strip('"')).encode()
                for part in body.split(boundary)[1:]:
                    if part.startswith(b'--'): continue
                    if part.startswith(b'\r\n'): part = part[2:]
                    if b'\r\n\r\n' not in part: continue
                    hdr, val = part.split(b'\r\n\r\n', 1)
                    if b'name="path"' in hdr:
                        b64 = val.strip().rstrip(b'\r\n').decode()
                        break
        else:
            params = {k: unquote_plus(v) for k,v in
                      (p.split('=',1) for p in body.decode().split('&') if '=' in p)}
            b64 = params.get('path','')

        path = _safe_path(b64)
        if not path or not os.path.isfile(path):
            self._json({'ok': False, 'error': 'Archivo no encontrado'}); return
        try:
            os.remove(path)
            threading.Thread(target=_trigger_scan, daemon=True).start()
            self._json({'ok': True})
        except Exception as e:
            self._json({'ok': False, 'error': str(e)})

    def _handle_ytdlp_update(self):
        try:
            r = subprocess.run(['yt-dlp', '-U'], capture_output=True, text=True, timeout=120)
            out = (r.stdout + r.stderr).strip()
            return self._json({'ok': r.returncode == 0, 'output': out[-800:], 'version': _ytdlp_version()})
        except Exception as e:
            return self._json({'ok': False, 'output': str(e), 'version': ''})

    def _handle_schedule(self):
        """Añade una URL a la cola nocturna."""
        content_type = self.headers.get('Content-Type', '')
        length       = int(self.headers.get('Content-Length', 0))
        body         = self.rfile.read(length)

        if 'multipart' in content_type:
            m = re.search(r'boundary=([^\s;]+)', content_type)
            params = {}
            if m:
                boundary = ('--' + m.group(1).strip('"')).encode()
                for part in body.split(boundary)[1:]:
                    if part.startswith(b'--'):
                        continue
                    if part.startswith(b'\r\n'):
                        part = part[2:]
                    if b'\r\n\r\n' not in part:
                        continue
                    hdr, val = part.split(b'\r\n\r\n', 1)
                    nm = re.search(rb'name="([^"]*)"', hdr)
                    if nm:
                        params[nm.group(1).decode()] = val.strip().rstrip(b'\r\n').decode('utf-8', errors='replace')
        else:
            params = {k: unquote_plus(v) for k, v in
                      (p.split('=', 1) for p in body.decode('utf-8', errors='replace').split('&') if '=' in p)}

        url       = params.get('url', '').strip()
        subfolder = (params.get('subfolder', '') or 'Descargas').strip()
        if not url:
            self._json({'ok': False, 'error': 'URL vacía'})
            return

        job = {
            'url':  url,
            'dest': os.path.join(MUSIC_DIR, subfolder),
            'status': 'scheduled',
            'added':  datetime.now().strftime('%H:%M:%S'),
        }
        with night_lock:
            # Evitar duplicados
            if not any(j['url'] == url for j in night_queue):
                night_queue.append(job)
            q = list(night_queue)
        self._json({'ok': True, 'queue': q})

    def _handle_unschedule(self):
        """Elimina una URL de la cola nocturna."""
        content_type = self.headers.get('Content-Type', '')
        length       = int(self.headers.get('Content-Length', 0))
        body         = self.rfile.read(length)

        if 'multipart' in content_type:
            m = re.search(r'boundary=([^\s;]+)', content_type)
            params = {}
            if m:
                boundary = ('--' + m.group(1).strip('"')).encode()
                for part in body.split(boundary)[1:]:
                    if part.startswith(b'--'):
                        continue
                    if part.startswith(b'\r\n'):
                        part = part[2:]
                    if b'\r\n\r\n' not in part:
                        continue
                    hdr, val = part.split(b'\r\n\r\n', 1)
                    nm = re.search(rb'name="([^"]*)"', hdr)
                    if nm:
                        params[nm.group(1).decode()] = val.strip().rstrip(b'\r\n').decode('utf-8', errors='replace')
        else:
            params = {k: unquote_plus(v) for k, v in
                      (p.split('=', 1) for p in body.decode('utf-8', errors='replace').split('&') if '=' in p)}

        url = params.get('url', '').strip()
        with night_lock:
            night_queue[:] = [j for j in night_queue if j['url'] != url]
            q = list(night_queue)
        self._json({'ok': True, 'queue': q})

    def _handle_spotify(self):
        """Importa una playlist de Spotify y encola las descargas."""
        content_type = self.headers.get('Content-Type', '')
        length       = int(self.headers.get('Content-Length', 0))
        body         = self.rfile.read(length)

        if 'multipart' in content_type:
            m = re.search(r'boundary=([^\s;]+)', content_type)
            params = {}
            if m:
                boundary = ('--' + m.group(1).strip('"')).encode()
                for part in body.split(boundary)[1:]:
                    if part.startswith(b'--'):
                        continue
                    if part.startswith(b'\r\n'):
                        part = part[2:]
                    if b'\r\n\r\n' not in part:
                        continue
                    hdr, val = part.split(b'\r\n\r\n', 1)
                    nm = re.search(rb'name="([^"]*)"', hdr)
                    if nm:
                        params[nm.group(1).decode()] = val.strip().rstrip(b'\r\n').decode('utf-8', errors='replace')
        else:
            params = {k: unquote_plus(v) for k, v in
                      (p.split('=', 1) for p in body.decode('utf-8', errors='replace').split('&') if '=' in p)}

        url = params.get('url', '').strip()
        if not url:
            self._json({'ok': False, 'error': 'URL vacía'})
            return

        try:
            tracks = _spotify_tracks(url)
        except Exception as e:
            self._json({'ok': False, 'error': str(e)})
            return

        dest = os.path.join(MUSIC_DIR, 'Descargas')
        for track in tracks:
            artist = track.get('artist', '')
            title  = track.get('title', '')
            search = f'ytsearch1:{artist} {title}'.strip()
            job = {
                'url':      search,
                'dest':     dest,
                'status':   'queued',
                'started':  '',
                'finished': '',
                'log':      [],
                'added':    datetime.now().strftime('%H:%M:%S'),
            }
            download_queue.put(job)

        self._json({'ok': True, 'count': len(tracks), 'tracks': tracks})


# ── Bootstrap .env ────────────────────────────────────────────────────────────
def _load_env():
    global PORT, MUSIC_DIR, NTFY_TOPIC, ND_URL, ND_ADMIN_USER, ND_ADMIN_PASS, MAX_UPLOAD_BYTES
    global SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET
    env_path = Path(__file__).parent.parent / '.env'
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            os.environ.setdefault(k.strip(), v.strip())
    PORT                  = int(os.environ.get('WEBQUEUE_PORT', PORT))
    MUSIC_DIR             = os.environ.get('MUSIC_DIR', MUSIC_DIR)
    NTFY_TOPIC            = os.environ.get('NTFY_TOPIC', NTFY_TOPIC)
    ND_URL                = os.environ.get('ND_URL', ND_URL)
    ND_ADMIN_USER         = os.environ.get('ND_ADMIN_USER', ND_ADMIN_USER)
    ND_ADMIN_PASS         = os.environ.get('ND_ADMIN_PASS', ND_ADMIN_PASS)
    MAX_UPLOAD_BYTES      = int(os.environ.get('MAX_UPLOAD_MB', MAX_UPLOAD_BYTES // 1024 // 1024)) * 1024 * 1024
    SPOTIFY_CLIENT_ID     = os.environ.get('SPOTIFY_CLIENT_ID', SPOTIFY_CLIENT_ID)
    SPOTIFY_CLIENT_SECRET = os.environ.get('SPOTIFY_CLIENT_SECRET', SPOTIFY_CLIENT_SECRET)


if __name__ == '__main__':
    _load_env()
    print(f'  Axcenmusic Web')
    print(f'  http://0.0.0.0:{PORT}')
    print(f'  Música en: {MUSIC_DIR}')
    print(f'  iPhone (Tailscale): http://pimusic:{PORT}')
    if not ND_ADMIN_USER:
        print(f'  [AVISO] ND_ADMIN_USER no configurado — botón de escaneo desactivado')
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n  Servidor detenido.')
