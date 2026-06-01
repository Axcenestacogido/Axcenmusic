#!/usr/bin/env python3
"""
Axcenmusic — Cola de descargas web
Interfaz web para descargar música desde YouTube/Bandcamp/SoundCloud
Accesible solo via Tailscale VPN en http://pimusic:8888

Sin dependencias externas (usa solo stdlib de Python 3).
"""
import os
import sys
import json
import queue
import threading
import subprocess
import time
import html
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote_plus
from datetime import datetime

# ── Configuración ──────────────────────────────────────────────────
PORT        = int(os.environ.get('WEBQUEUE_PORT', '8888'))
MUSIC_DIR   = os.environ.get('MUSIC_DIR', '/mnt/music')
NTFY_TOPIC  = os.environ.get('NTFY_TOPIC', '')
DEFAULT_DEST = os.path.join(MUSIC_DIR, 'Descargas')

# ── Estado compartido ─────────────────────────────────────────────
download_queue  = queue.Queue()
history         = []        # lista de dicts con estado de cada descarga
current_job     = None      # job activo
current_log     = []        # líneas de log del job activo
state_lock      = threading.Lock()

# ── Worker de descarga ────────────────────────────────────────────
def download_worker():
    global current_job, current_log
    while True:
        job = download_queue.get()
        with state_lock:
            current_job = job
            current_log = []
            job['status'] = 'downloading'
            job['started'] = datetime.now().strftime('%H:%M:%S')

        dest = job.get('dest', DEFAULT_DEST)
        os.makedirs(dest, exist_ok=True)

        cmd = [
            'yt-dlp',
            '--extract-audio',
            '--audio-format', 'mp3',
            '--audio-quality', '0',
            '--embed-thumbnail',
            '--embed-metadata',
            '--add-metadata',
            '--output', os.path.join(dest, '%(artist)s - %(title)s.%(ext)s'),
            '--newline',
            job['url'],
        ]

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
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

        # Notificación ntfy
        if NTFY_TOPIC and success:
            try:
                import urllib.request
                req = urllib.request.Request(
                    f'https://ntfy.sh/{NTFY_TOPIC}',
                    data=f"Descarga completada: {job['url'][:60]}".encode(),
                    headers={'Title': 'Axcenmusic — Descarga', 'Tags': 'musical_note'},
                    method='POST'
                )
                urllib.request.urlopen(req, timeout=5)
            except Exception:
                pass

        download_queue.task_done()

threading.Thread(target=download_worker, daemon=True).start()

# ── HTML ──────────────────────────────────────────────────────────
def render_page():
    with state_lock:
        job      = dict(current_job) if current_job else None
        log      = list(current_log)
        hist     = list(history)
        q_size   = download_queue.qsize()

    status_badge = lambda s: {
        'downloading': '<span style="color:#4ade80">⟳ Descargando</span>',
        'done':        '<span style="color:#4ade80">✓ Completada</span>',
        'error':       '<span style="color:#f87171">✗ Error</span>',
        'queued':      '<span style="color:#facc15">· En cola</span>',
    }.get(s, s)

    log_html = ''
    if job:
        log_lines = html.escape('\n'.join(log[-25:]))
        log_html = f'''
        <div class="card">
          <h2>⟳ Descargando ahora</h2>
          <p><b>URL:</b> {html.escape(job["url"][:80])}</p>
          <p><b>Destino:</b> {html.escape(job.get("dest",""))}</p>
          <pre class="logbox">{log_lines}</pre>
        </div>'''

    hist_rows = ''
    for h in hist[:15]:
        hist_rows += f'''
        <tr>
          <td>{status_badge(h["status"])}</td>
          <td style="word-break:break-all">{html.escape(h["url"][:70])}</td>
          <td>{html.escape(h.get("started",""))}</td>
          <td>{html.escape(h.get("dest","").replace(MUSIC_DIR, "…"))}</td>
        </tr>'''

    return f'''<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta http-equiv="refresh" content="8">
  <title>Axcenmusic — Descargas</title>
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    body{{background:#18181b;color:#e4e4e7;font-family:system-ui,sans-serif;padding:20px;max-width:900px;margin:0 auto}}
    h1{{color:#4ade80;margin-bottom:6px}}
    h2{{color:#a1a1aa;font-size:1rem;margin-bottom:12px}}
    .card{{background:#27272a;border-radius:10px;padding:18px;margin:16px 0}}
    input,select{{background:#3f3f46;border:1px solid #52525b;color:#e4e4e7;
                  border-radius:6px;padding:8px 12px;width:100%;margin:6px 0;font-size:0.95rem}}
    button{{background:#4ade80;color:#18181b;border:none;border-radius:6px;
            padding:10px 24px;font-size:1rem;font-weight:700;cursor:pointer;margin-top:8px}}
    button:hover{{background:#86efac}}
    pre.logbox{{background:#18181b;border-radius:6px;padding:12px;font-size:0.78rem;
                overflow-x:auto;max-height:260px;overflow-y:auto;color:#86efac;white-space:pre-wrap}}
    table{{width:100%;border-collapse:collapse;font-size:0.88rem}}
    th{{text-align:left;color:#71717a;padding:6px 10px;border-bottom:1px solid #3f3f46}}
    td{{padding:8px 10px;border-bottom:1px solid #27272a;vertical-align:top}}
    .badge{{background:#3f3f46;border-radius:20px;padding:2px 10px;font-size:0.8rem}}
    .sub{{color:#71717a;font-size:0.82rem;margin-top:4px}}
  </style>
</head>
<body>
  <h1>🎵 Axcenmusic</h1>
  <p class="sub">Cola de descargas · acceso via Tailscale · se refresca cada 8 s</p>

  <div class="card">
    <h2>Nueva descarga</h2>
    <form method="post" action="/add">
      <label>URL (YouTube, Bandcamp, SoundCloud…)</label>
      <input name="url" type="url" placeholder="https://youtube.com/watch?v=..." required>
      <label style="margin-top:10px">Carpeta destino (dentro de {html.escape(MUSIC_DIR)})</label>
      <input name="subfolder" placeholder="Descargas" value="Descargas">
      <button type="submit">Añadir a la cola</button>
    </form>
    <p class="sub" style="margin-top:10px">En cola: <b>{q_size}</b></p>
  </div>

  {log_html}

  <div class="card">
    <h2>Historial de descargas</h2>
    {'<p style="color:#71717a">Sin descargas todavía.</p>' if not hist else f"""
    <table>
      <tr><th>Estado</th><th>URL</th><th>Inicio</th><th>Destino</th></tr>
      {hist_rows}
    </table>"""}
  </div>

  <div class="card">
    <h2>Instrucciones rápidas</h2>
    <p>1. Pega cualquier URL de YouTube, Bandcamp o SoundCloud.</p>
    <p>2. Elige la subcarpeta dentro de tu biblioteca (Artista/Album recomendado).</p>
    <p>3. Pulsa Añadir — la descarga empieza automáticamente.</p>
    <p style="margin-top:8px" class="sub">Tras descargar, ve a Navidrome → Escanear biblioteca para que aparezca la música.</p>
  </div>
</body>
</html>'''

# ── Handler HTTP ─────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # silenciar logs de acceso

    def send_html(self, body, code=200):
        data = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', len(data))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_html(render_page())

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != '/add':
            self.send_html('<p>Not found</p>', 404)
            return

        length  = int(self.headers.get('Content-Length', 0))
        body    = self.rfile.read(length).decode('utf-8')
        params  = {k: unquote_plus(v) for k, v in
                   (p.split('=', 1) for p in body.split('&') if '=' in p)}

        url       = params.get('url', '').strip()
        subfolder = params.get('subfolder', 'Descargas').strip() or 'Descargas'
        dest      = os.path.join(MUSIC_DIR, subfolder)

        if not url:
            self.send_html('<p>URL vacía</p><a href="/">Volver</a>', 400)
            return

        job = {
            'url':     url,
            'dest':    dest,
            'status':  'queued',
            'started': '',
            'finished':'',
            'log':     [],
            'added':   datetime.now().strftime('%H:%M:%S'),
        }
        download_queue.put(job)

        # Redirect back
        self.send_response(303)
        self.send_header('Location', '/')
        self.end_headers()

# ── Main ──────────────────────────────────────────────────────────
if __name__ == '__main__':
    # Cargar .env si existe
    env_path = Path(__file__).parent.parent / '.env'
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                os.environ.setdefault(k.strip(), v.strip())
        MUSIC_DIR  = os.environ.get('MUSIC_DIR', MUSIC_DIR)
        NTFY_TOPIC = os.environ.get('NTFY_TOPIC', NTFY_TOPIC)
        PORT       = int(os.environ.get('WEBQUEUE_PORT', PORT))

    print(f'  Axcenmusic Web Queue')
    print(f'  Escuchando en http://0.0.0.0:{PORT}')
    print(f'  Música en: {MUSIC_DIR}')
    print(f'  Accede desde el iPhone via Tailscale: http://pimusic:{PORT}')

    server = HTTPServer(('0.0.0.0', PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n  Servidor detenido.')
