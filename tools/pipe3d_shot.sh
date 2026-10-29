#!/usr/bin/env bash
# Nimmt die raeumliche Pipeline headless auf (doc/spec/107 §107.1b).
#
# EIGENE Anzeigenummer je Lauf und Warten auf Xvfb: mit einer festen Nummer
# scheiterte jeder zweite Lauf an „glfwInit failed", der Greifer kopierte
# dann das ALTE Bild — und zwei Aufnahmen sahen identisch aus, obwohl sich
# das Bild sehr wohl geaendert hatte (verloren: eine Stunde, 2026-10-16).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=doc/spec/ui/shots
mkdir -p "$OUT"
DISP=":$(( 90 + (RANDOM % 60) ))"
Xvfb "$DISP" -screen 0 1280x720x24 >"$OUT/xvfb3d.log" 2>&1 &
XPID=$!
for _ in $(seq 1 50); do
    DISPLAY="$DISP" xdpyinfo >/dev/null 2>&1 && break
    sleep 0.1
done
if ! DISPLAY="$DISP" xdpyinfo >/dev/null 2>&1; then
    echo "Pipe3D FEHLER: Xvfb auf $DISP kam nicht hoch"; kill $XPID 2>/dev/null; exit 1
fi
# P3D_SCENE=cluster nimmt das NETZ auf (doc/spec/107 §107.5a) — eigener Dateiname,
# damit nicht eine Aufnahme die andere ueberschreibt.
NAME="Pipe3D"
[ "${P3D_SCENE:-}" = "cluster" ] && NAME="Cluster3D"
[ "${P3D_SCENE:-}" = "layers" ] && NAME="Layers3D"
[ "${P3D_SCENE:-}" = "flagge" ] && NAME="Flagge3D"
DISPLAY="$DISP" P3D_HOLD="${P3D_HOLD:-2500}" P3D_PHASE="${P3D_PHASE:-0}" P3D_SCENE="${P3D_SCENE:-}" ./pipe3d_shot >"$OUT/$NAME.log" 2>&1 &
APID=$!
sleep 1.4
DISPLAY="$DISP" import -window root "$OUT/$NAME.png" 2>>"$OUT/$NAME.log"
wait $APID; rc=$?
kill $XPID 2>/dev/null; wait $XPID 2>/dev/null
if ! grep -q "pipe3d_shot done" "$OUT/$NAME.log"; then
    echo "$NAME FEHLER: Probe lief nicht durch (siehe $OUT/$NAME.log)"; exit 1
fi
printf '%s rc=%s  %s  %s\n' "$NAME" "$rc" "$(ls -la "$OUT/$NAME.png" 2>/dev/null | awk '{print $5" B"}')" "$(grep -oE 'Pixelsumme: [0-9]+' "$OUT/$NAME.log" | tail -1)"
exit $rc
