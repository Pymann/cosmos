#!/bin/bash
# Sammelt alles, was der Agent auf einem Knoten zum Laufen braucht
# (doc/spec/94 Schritt 5), nach deploy/runtime/.
#
# Mitgeliefert wird die TATSAECHLICHE Ladekette von libaiml.so und agent —
# nicht nur die neun, die auf DIESEM Rechner aus dem exodus-Cache kommen
# (User 2026-10-13: auf dem Knoten darf nichts vorausgesetzt werden).  Also
# reisen auch libLLVM, libGL, X11 und openblas mit, selbst wenn sie hier
# zufaellig systemweit installiert sind.
#
# NICHT mitgeliefert wird die universelle Basis (libc, libm, libstdc++,
# libgcc_s, ld-linux, …): die gehoert zum Betriebssystem des Knotens, und eine
# fremde libc neben dem eigenen Lader ist keine Portabilitaet, sondern ein
# Absturz.  `lib*.so` ohne Versionsnummer (Entwickler-Symlinks) und
# Linker-Skripte wie libc.so bleiben ebenfalls draussen.
set -euo pipefail

AIML_DIR="${AIML_DIR:-/media/nikolai/95a208ef-ffa2-478b-abdd-ff394baa6a76/projects/python/test/aiml}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/deploy/runtime"
LIB="$AIML_DIR/out/libaiml/libaiml.so"
AGENT="$HERE/agent"

[ -f "$LIB" ]   || { echo "FEHLER: $LIB fehlt — erst 'exodus build --all' in aiml" >&2; exit 1; }
[ -f "$AGENT" ] || { echo "FEHLER: $AGENT fehlt — erst 'exodus build --all' in cosmos" >&2; exit 1; }

# Aufbau des Buendels = Aufbau auf dem Knoten:
#   <install_dir>/bwrap        der Sandkasten (eigene Kopie, s.u.)
#   <install_dir>/lib/*.so     die Ladekette; der Agent findet sie per $ORIGIN/lib
rm -rf "$OUT"; mkdir -p "$OUT/lib"
cp -L "$LIB" "$OUT/lib/libaiml.so"

# bubblewrap reist MIT: so braucht der Knoten kein Paket, und das
# AppArmor-Profil kann `userns` genau UNSERER Kopie erlauben statt dem
# systemweiten /usr/bin/bwrap (das unberechtigt bleibt).
BWRAP="$(command -v bwrap || true)"
[ -n "$BWRAP" ] || { echo "FEHLER: bwrap nicht gefunden (apt install bubblewrap)" >&2; exit 1; }
cp -L "$BWRAP" "$OUT/bwrap"
chmod 0755 "$OUT/bwrap"

# Zum Betriebssystem gehoerig — niemals mitliefern.
base_re='^(libc|libm|libdl|librt|libpthread|libstdc\+\+|libgcc_s|ld-linux.*|libresolv|libnss_.*)\.so'

count=0
for src in "$LIB" "$AGENT" "$BWRAP"; do
    while read -r dep; do
        base="$(basename "$dep")"
        [[ "$base" =~ $base_re ]] && continue
        [ -e "$OUT/lib/$base" ] && continue
        cp -L "$dep" "$OUT/lib/$base" && count=$((count+1))
    done < <(ldd "$src" 2>/dev/null | awk '$3 ~ /^\// {print $3}')
done

# Ein Archiv statt 44 Einzeldateien: die Einrichtung streamt EINEN Payload und
# packt ihn auf dem Knoten aus — 88 SSH-Schritte waeren dasselbe in langsam.
# --owner/--group 0: ein als Entwickler gepacktes Archiv darf auf dem Knoten
# keine unprivilegierten Eigentuemer wiederherstellen — AppArmor berechtigt
# /opt/cosmos/bwrap, und wer diese Datei ersetzen kann, erbt die Berechtigung.
tar --owner=0 --group=0 --numeric-owner -czf "$HERE/deploy/runtime.tar.gz" -C "$OUT" .

echo "deploy/runtime: libaiml.so + bwrap + $count Bibliotheken"
du -sh "$OUT" | awk '{print "entpackt: " $1}'
du -sh "$HERE/deploy/runtime.tar.gz" | awk '{print "Archiv:   " $1}'
