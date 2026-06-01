#!/usr/bin/env python3
"""
Análisis de BPM y volumen para la biblioteca de música.
Genera un CSV de caché usado por dj.sh para crear playlists inteligentes.

Uso: python3 scripts/analyze.py [directorio] [--cache ruta.csv]
"""
import os
import sys
import csv
import subprocess
import json
import time
import argparse
from pathlib import Path

AUDIO_EXTS = {'.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav', '.aiff'}

def get_bpm(filepath: str) -> float:
    """Detecta el BPM usando la librería aubio."""
    try:
        import aubio
        samplerate, win_s, hop_s = 0, 1024, 512
        src = aubio.source(filepath, samplerate, hop_s)
        samplerate = src.samplerate
        tempo = aubio.tempo("default", win_s, hop_s, samplerate)
        beats = []
        while True:
            samples, read = src()
            is_beat = tempo(samples)
            if is_beat:
                beats.append(tempo.get_last_s())
            if read < hop_s:
                break
        if len(beats) < 2:
            return 0.0
        intervals = [beats[i+1] - beats[i] for i in range(len(beats)-1)]
        avg_interval = sum(intervals) / len(intervals)
        return round(60.0 / avg_interval, 1) if avg_interval > 0 else 0.0
    except Exception:
        return 0.0

def get_loudness(filepath: str) -> float:
    """Obtiene el volumen medio en dBFS usando ffmpeg."""
    try:
        result = subprocess.run(
            ['ffmpeg', '-i', filepath, '-af', 'volumedetect',
             '-vn', '-sn', '-dn', '-f', 'null', '-'],
            capture_output=True, text=True, timeout=60
        )
        for line in result.stderr.splitlines():
            if 'mean_volume' in line:
                return float(line.split(':')[1].strip().replace(' dB', ''))
        return -99.0
    except Exception:
        return -99.0

def get_tags(filepath: str) -> dict:
    """Lee tags básicos con ffprobe."""
    try:
        result = subprocess.run(
            ['ffprobe', '-v', 'quiet', '-print_format', 'json',
             '-show_format', filepath],
            capture_output=True, text=True, timeout=30
        )
        data = json.loads(result.stdout)
        tags = data.get('format', {}).get('tags', {})
        duration = float(data.get('format', {}).get('duration', 0))
        # Normaliza claves (pueden ser mayúsculas o minúsculas)
        tags_lower = {k.lower(): v for k, v in tags.items()}
        return {
            'title':    tags_lower.get('title', ''),
            'artist':   tags_lower.get('artist', ''),
            'album':    tags_lower.get('album', ''),
            'genre':    tags_lower.get('genre', ''),
            'duration': round(duration),
        }
    except Exception:
        return {'title': '', 'artist': '', 'album': '', 'genre': '', 'duration': 0}

def find_audio_files(directory: str):
    """Devuelve todos los archivos de audio bajo el directorio."""
    for root, _, files in os.walk(directory):
        for f in sorted(files):
            if Path(f).suffix.lower() in AUDIO_EXTS:
                yield os.path.join(root, f)

def load_cache(cache_path: str) -> dict:
    """Carga el CSV de caché existente."""
    cache = {}
    if not os.path.exists(cache_path):
        return cache
    try:
        with open(cache_path, newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                cache[row['filepath']] = row
    except Exception:
        pass
    return cache

def save_cache(cache_path: str, data: dict):
    """Guarda el CSV de caché."""
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    fieldnames = ['filepath', 'bpm', 'loudness', 'duration',
                  'title', 'artist', 'album', 'genre']
    with open(cache_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(data.values())

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', nargs='?', default='/mnt/music')
    parser.add_argument('--cache', default='/opt/axcenmusic/.cache/music-analysis.csv')
    args = parser.parse_args()

    # Comprobar aubio
    try:
        import aubio
        has_aubio = True
    except ImportError:
        print("  ⚠  aubio no está instalado. Se analizará solo el volumen.")
        print("     Instala con: pip3 install aubio")
        has_aubio = False

    # Cargar caché existente
    cache = load_cache(args.cache)

    # Encontrar todos los archivos
    all_files = list(find_audio_files(args.directory))
    total = len(all_files)
    if total == 0:
        print(f"  No se encontraron archivos de audio en {args.directory}")
        sys.exit(0)

    # Estimar tiempo
    already_done = sum(1 for f in all_files if f in cache)
    pending = total - already_done
    secs_per_song = 3 if has_aubio else 1
    eta_min = (pending * secs_per_song) // 60
    print(f"\n  Archivos totales:     {total}")
    print(f"  Ya analizados:        {already_done}")
    print(f"  Pendientes:           {pending}")
    if pending > 0:
        print(f"  Tiempo estimado:      ~{eta_min} minutos")
    print()

    analyzed = 0
    skipped = 0
    errors = 0

    for i, filepath in enumerate(all_files, 1):
        rel = os.path.relpath(filepath, args.directory)

        # Saltar si ya está en caché
        if filepath in cache:
            skipped += 1
            continue

        # Progreso
        pct = int((i / total) * 40)
        bar = '█' * pct + '░' * (40 - pct)
        print(f"\r  [{bar}] {i}/{total}  {rel[:50]:<50}", end='', flush=True)

        try:
            tags = get_tags(filepath)
            bpm = get_bpm(filepath) if has_aubio else 0.0
            loudness = get_loudness(filepath)

            cache[filepath] = {
                'filepath': filepath,
                'bpm':      bpm,
                'loudness': loudness,
                'duration': tags['duration'],
                'title':    tags['title'],
                'artist':   tags['artist'],
                'album':    tags['album'],
                'genre':    tags['genre'],
            }
            analyzed += 1

            # Guardar cada 10 canciones para no perder progreso
            if analyzed % 10 == 0:
                save_cache(args.cache, cache)

        except Exception as e:
            errors += 1

    # Guardar caché final
    save_cache(args.cache, cache)

    print(f"\n\n  ✓  Análisis completado")
    print(f"     Analizados:   {analyzed}")
    print(f"     Ya existían:  {skipped}")
    print(f"     Errores:      {errors}")
    print(f"     Caché en:     {args.cache}")
    print()

if __name__ == '__main__':
    main()
