#!/usr/bin/env python3
"""
Axcenmusic — Interfaz web
- Subir archivos de música directamente desde el navegador
- Descargar desde YouTube / Bandcamp / SoundCloud via yt-dlp
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
import urllib.request
import urllib.parse
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

AUDIO_EXTS = {'.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav', '.aac', '.wma', '.aiff', '.alac'}

# ── Estado compartido ──────────────────────────────────────────────────────────
download_queue = queue.Queue()
history        = []   # descargas por URL
uploads        = []   # archivos subidos directamente
current_job    = None
current_log    = []
state_lock     = threading.Lock()


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


# ── Letras automáticas ────────────────────────────────────────────────────────
def _run_lyrics(folder):
    script = Path(__file__).parent.parent / 'scripts' / 'lyrics.sh'
    if not script.exists():
        return
    try:
        subprocess.run(['bash', str(script), folder], timeout=120)
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

def _list_songs():
    songs = []
    for root, _, files in os.walk(MUSIC_DIR):
        for fn in sorted(files):
            if Path(fn).suffix.lower() not in AUDIO_EXTS:
                continue
            path = os.path.join(root, fn)
            try:
                tags = _read_tags(path)
                songs.append({
                    'p': base64.b64encode(path.encode()).decode(),
                    'f': fn,
                    'r': os.path.relpath(path, MUSIC_DIR),
                    't': tags.get('title', Path(fn).stem),
                    'ar': tags.get('artist', ''),
                    'al': tags.get('album', ''),
                    'ge': tags.get('genre', ''),
                    'sz': f'{os.path.getsize(path) / 1048576:.1f} MB',
                })
            except Exception:
                pass
    return songs

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
    try:
        cmd = ['ffmpeg', '-y', '-i', file_path]
        if cover_data:
            ctmp = tempfile.NamedTemporaryFile(suffix='.jpg', delete=False)
            ctmp.write(cover_data)
            ctmp.close()
            cmd += ['-i', ctmp.name, '-map', '0:a', '-map', '1:0']
        cmd += ['-codec', 'copy', '-id3v2_version', '3', '-map_metadata', '0']
        if title  is not None: cmd += ['-metadata', f'title={title}']
        if artist is not None: cmd += ['-metadata', f'artist={artist}']
        if album  is not None: cmd += ['-metadata', f'album={album}']
        if genre  is not None: cmd += ['-metadata', f'genre={genre}']
        if cover_data:
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

    # Descarga activa
    active_html = ''
    if job:
        log_text = html.escape('\n'.join(log[-25:]))
        active_html = f'''
        <div class="card">
          <div class="card-title">⟳ Descargando ahora</div>
          <p><b>URL:</b> {html.escape(job["url"][:80])}</p>
          <p><b>Destino:</b> {html.escape(job.get("dest","").replace(MUSIC_DIR,"…"))}</p>
          <pre class="logbox">{log_text}</pre>
        </div>'''

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

    return f'''<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Axcenmusic</title>
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
    input[type=url],input[type=text]{{
      background:#3f3f46;border:1px solid #52525b;color:#e4e4e7;
      border-radius:8px;padding:9px 12px;width:100%;font-size:.95rem;margin-bottom:10px}}
    input[type=url]:focus,input[type=text]:focus{{outline:none;border-color:#f59e0b}}
    .btn{{background:#f59e0b;color:#18181b;border:none;border-radius:8px;
          padding:11px 22px;font-size:1rem;font-weight:700;cursor:pointer;
          width:100%;margin-top:4px}}
    .btn:hover{{background:#fbbf24}}
    .btn-scan{{background:#3f3f46;color:#e4e4e7;border:none;border-radius:8px;
               padding:9px 18px;font-size:.9rem;font-weight:600;cursor:pointer}}
    .btn-scan:hover{{background:#52525b}}
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
  </style>
</head>
<body>
  <h1>🎵 Axcenmusic</h1>
  <p class="sub">Interfaz web · solo accesible via Tailscale</p>

  {flash_html}

  <div class="tabs">
    <div class="tab active" onclick="switchTab('upload')">Subir</div>
    <div class="tab" onclick="switchTab('download')">Descargar</div>
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

  <!-- ── DESCARGAR URL ── -->
  <div id="tab-download" class="tab-content">
    <div class="card">
      <div class="card-title">Descargar desde URL</div>
      <form method="post" action="/add">
        <label>URL (YouTube, Bandcamp, SoundCloud…)</label>
        <input type="url" name="url" placeholder="https://youtube.com/watch?v=..." required>
        <label>Subcarpeta destino</label>
        <input type="text" name="subfolder" value="Descargas" placeholder="Artista/Album">
        <button type="submit" class="btn">Añadir a la cola</button>
      </form>
      <p class="muted" style="margin-top:8px">En cola: <b>{q_size}</b></p>
    </div>
    {active_html}
  </div>

  <!-- ── BIBLIOTECA ── -->
  <div id="tab-library" class="tab-content">
    <div class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
        <span>Canciones en la biblioteca</span>
        <button class="btn-scan" onclick="loadLibrary()">↺ Recargar</button>
      </div>
      <div id="lib-loading" class="muted">Cargando…</div>
      <div id="lib-list"></div>
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
  const TAB_NAMES = ['upload','download','library','history'];
  function switchTab(name) {{
    document.querySelectorAll('.tab').forEach((t,i) =>
      t.classList.toggle('active', TAB_NAMES[i] === name));
    document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
    document.getElementById('tab-' + name).classList.add('active');
    if (name === 'library') loadLibrary();
  }}

  // ── Biblioteca ────────────────────────────────────────────────────
  async function loadLibrary() {{
    document.getElementById('lib-loading').textContent = 'Cargando…';
    document.getElementById('lib-list').innerHTML = '';
    let songs;
    try {{
      const r = await fetch('/api/library');
      songs = await r.json();
    }} catch(e) {{
      document.getElementById('lib-loading').textContent = 'Error al cargar la biblioteca.';
      return;
    }}
    document.getElementById('lib-loading').style.display = 'none';
    if (!songs.length) {{
      document.getElementById('lib-list').innerHTML = '<p class="muted">Sin canciones todavía.</p>';
      return;
    }}
    const rows = songs.map(s => `
      <div style="display:flex;align-items:center;gap:10px;padding:10px 0;
                  border-bottom:1px solid #3f3f46">
        <img src="/cover?p=${{encodeURIComponent(s.p)}}" alt=""
             style="width:44px;height:44px;object-fit:cover;border-radius:6px;
                    background:#3f3f46;flex-shrink:0"
             onerror="this.style.background='#3f3f46';this.src=''">
        <div style="flex:1;min-width:0">
          <div style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
            ${{escHtml(s.t)}}</div>
          <div class="muted" style="font-size:.8rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
            ${{escHtml(s.ar || '—')}} · ${{escHtml(s.al || '—')}} · ${{s.sz}}</div>
        </div>
        <button class="btn-scan" style="padding:6px 10px;font-size:.8rem"
                onclick='openEdit("${{s.p}}","${{escJs(s.t)}}","${{escJs(s.ar)}}","${{escJs(s.al)}}","${{escJs(s.ge)}}")'>
          ✎
        </button>
        <button class="btn-scan" style="padding:6px 10px;font-size:.8rem;color:#f87171"
                onclick='deleteSong("${{s.p}}","${{escJs(s.t)}}")'>
          🗑
        </button>
      </div>`).join('');
    document.getElementById('lib-list').innerHTML = rows;
  }}

  function escJs(s) {{
    return (s||'').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
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
    img.src = '/cover?p=' + encodeURIComponent(pathB64);
    img.style.display = 'block';
    document.getElementById('edit-modal').style.display = 'flex';
  }}

  function closeModal() {{
    document.getElementById('edit-modal').style.display = 'none';
  }}

  function previewCover(input) {{
    if (!input.files[0]) return;
    const reader = new FileReader();
    reader.onload = e => {{
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
      if (res.ok) {{ closeModal(); loadLibrary(); }}
      else {{ errEl.textContent = res.error || 'Error desconocido'; errEl.style.display='block'; }}
    }} catch(e) {{
      errEl.textContent = 'Error de red'; errEl.style.display = 'block';
    }}
  }}

  // ── Eliminar canción ─────────────────────────────────────────────
  async function deleteSong(pathB64, title) {{
    if (!confirm('¿Eliminar "' + title + '"?\\nEsta acción no se puede deshacer.')) return;
    const fd = new FormData();
    fd.append('path', pathB64);
    try {{
      const r   = await fetch('/delete', {{method:'POST', body: fd}});
      const res = await r.json();
      if (res.ok) loadLibrary();
      else alert('Error: ' + (res.error || 'desconocido'));
    }} catch(e) {{
      alert('Error de red');
    }}
  }}

  // ── Drag & drop ──────────────────────────────────────────────────
  const dz = document.getElementById('dropzone');
  dz.addEventListener('dragover', e => {{ e.preventDefault(); dz.classList.add('drag'); }});
  dz.addEventListener('dragleave', () => dz.classList.remove('drag'));
  dz.addEventListener('drop', e => {{
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
    for (const f of files) {{
      const div = document.createElement('div');
      div.className = 'file-item';
      div.innerHTML = '<span class="fname">' + escHtml(f.name) + '</span>'
                    + '<span class="fsize">' + fmtSize(f.size) + '</span>';
      list.appendChild(div);
    }}
  }}

  function escHtml(s) {{
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }}

  // ── Upload ───────────────────────────────────────────────────────
  function startUpload() {{
    const input = document.getElementById('file-input');
    if (!input.files.length) {{ alert('Elige al menos un archivo.'); return; }}

    const subfolder = document.getElementById('subfolder-upload').value || 'Subidas';
    const fd = new FormData();
    fd.append('subfolder', subfolder);
    for (const f of input.files) fd.append('files', f);

    document.getElementById('progress-wrap').style.display = 'block';
    document.getElementById('btn-upload').disabled = true;

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/upload');

    xhr.upload.onprogress = e => {{
      if (e.lengthComputable) {{
        const pct = Math.round(e.loaded / e.total * 100);
        document.getElementById('progress-bar').style.width = pct + '%';
        document.getElementById('progress-label').textContent = pct + '%  ('
          + fmtSize(e.loaded) + ' / ' + fmtSize(e.total) + ')';
      }}
    }};

    xhr.onload = () => {{
      document.getElementById('btn-upload').disabled = false;
      if (xhr.status === 200) {{
        const res = JSON.parse(xhr.responseText);
        document.getElementById('progress-label').textContent =
          res.ok + ' archivo(s) subido(s). ' + (res.errors.length ? 'Errores: ' + res.errors.join(', ') : '');
        document.getElementById('progress-bar').style.width = '100%';
        document.getElementById('file-list').innerHTML = '';
        input.value = '';
        setTimeout(() => location.reload(), 1500);
      }} else {{
        document.getElementById('progress-label').textContent = 'Error: ' + xhr.responseText;
      }}
    }};

    xhr.onerror = () => {{
      document.getElementById('btn-upload').disabled = false;
      document.getElementById('progress-label').textContent = 'Error de red.';
    }};

    xhr.send(fd);
  }}
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
        import json
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

        if parsed.path == '/api/library':
            self._json(_list_songs())
        elif parsed.path == '/cover':
            self._handle_cover(qs)
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
        else:
            self._html('<p>Not found</p>', 404)

    def _handle_add(self):
        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length).decode('utf-8')
        params = {k: unquote_plus(v) for k, v in
                  (p.split('=', 1) for p in body.split('&') if '=' in p)}
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
            threading.Thread(target=_run_lyrics, args=(last_dest,), daemon=True).start()

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
        self.send_header('Cache-Control', 'max-age=3600')
        self.end_headers()
        self.wfile.write(data)

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


# ── Bootstrap .env ────────────────────────────────────────────────────────────
def _load_env():
    global PORT, MUSIC_DIR, NTFY_TOPIC, ND_URL, ND_ADMIN_USER, ND_ADMIN_PASS, MAX_UPLOAD_BYTES
    env_path = Path(__file__).parent.parent / '.env'
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            os.environ.setdefault(k.strip(), v.strip())
    PORT             = int(os.environ.get('WEBQUEUE_PORT', PORT))
    MUSIC_DIR        = os.environ.get('MUSIC_DIR', MUSIC_DIR)
    NTFY_TOPIC       = os.environ.get('NTFY_TOPIC', NTFY_TOPIC)
    ND_URL           = os.environ.get('ND_URL', ND_URL)
    ND_ADMIN_USER    = os.environ.get('ND_ADMIN_USER', ND_ADMIN_USER)
    ND_ADMIN_PASS    = os.environ.get('ND_ADMIN_PASS', ND_ADMIN_PASS)
    MAX_UPLOAD_BYTES = int(os.environ.get('MAX_UPLOAD_MB', MAX_UPLOAD_BYTES // 1024 // 1024)) * 1024 * 1024


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
