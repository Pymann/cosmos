#!/usr/bin/env bash
# Prueft, dass der Fluss im Rohr sich WIRKLICH bewegt (doc/spec/107 F107-14).
#
# Zwei Aufnahmen mit verschiedener Phase muessen verschiedene Bilder ergeben.
# Gemessen wird am Bildspeicher (Pixelsumme aus gl.read_rgba8), nicht am
# Bildschirmgreifer: der lieferte bei einem fehlgeschlagenen Xvfb-Start das
# ALTE Bild und behauptete damit Stillstand, den es nicht gab (2026-10-16).
set -uo pipefail
cd "$(dirname "$0")/.."
sum_for() {
    P3D_PHASE="$1" tools/pipe3d_shot.sh >/dev/null 2>&1 || return 1
    grep -oE 'Pixelsumme: [0-9]+' doc/spec/ui/shots/Pipe3D.log | tail -1 | grep -oE '[0-9]+'
}
a=$(sum_for 0)   || { echo "[fluss] FEHLER: Aufnahme 1 scheiterte"; exit 1; }
b=$(sum_for 400) || { echo "[fluss] FEHLER: Aufnahme 2 scheiterte"; exit 1; }
[ -n "$a" ] && [ -n "$b" ] || { echo "[fluss] FEHLER: keine Messwerte"; exit 1; }
if [ "$a" = "$b" ]; then
    echo "[fluss] FAIL: Phase 0 und 400 ms ergeben dasselbe Bild ($a) — nichts bewegt sich"
    exit 1
fi
echo "[fluss] ok   Bewegung nachgewiesen (Phase 0: $a, Phase 400: $b)"
