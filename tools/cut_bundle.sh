#!/usr/bin/env bash
# Der CUT (doc/spec/110 §110.24): den Stand nach einem Bauschritt festhalten,
# damit die folgenden Laeufe nicht wieder dort anfangen.
#
#   tools/cut_bundle.sh <bundle-verzeichnis> <name>
#
# Der Schnitt laeuft IM NAMESPACE, nicht daneben: Dateien, die `apt` unter
# abgebildeten Kennungen angelegt hat (z.B. `_apt`), sind von aussen weder
# lesbar noch kopierbar — innen sind sie es.  Das ist derselbe Grund, aus dem
# `podman unshare` existiert.
#
# Die Adresse ist der INHALT (sortiert gehasht), nicht der Name — der Vertrag
# aus doc/spec/96, unabhaengig davon, ob der Stand per overlay-upper oder per
# Kopie entstand (F110-12).
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE="${1:?Bundle fehlt}"
NAME="${2:?Name fehlt}"
SRC="$(cd "$BUNDLE/rootfs" && pwd)"
mkdir -p deploy/rt_cuts
DST="$(cd deploy/rt_cuts && pwd)"

WORK="logs/rt_builds/.cut-$NAME"
./tools/make_build_bundle.sh ".cut-$NAME" '
set -e
rm -rf "/dst/'"$NAME"'"
cp -a /src "/dst/'"$NAME"'"
cd /src
ADDR=$(find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
printf "addr=%s\ndateien=%s\n" "$ADDR" "$(find . -type f | wc -l)" > "/dst/'"$NAME"'.manifest"
echo "[cut] '"$NAME"' → $ADDR"
du -sh "/dst/'"$NAME"'" | cut -f1 | xargs echo "[cut] Groesse:"
' "$SRC:/src" >/dev/null

# Zweiter Bind (Ziel, schreibbar) — der Bundle-Bauer kann nur einen.
python3 - "$WORK" "$DST" <<'PY'
import json, io, sys, os
work, dst = sys.argv[1], sys.argv[2]
cfg = json.load(io.open(work + "/config.json", encoding="utf-8"))
os.makedirs(work + "/rootfs/dst", exist_ok=True)
cfg["mounts"].append({"destination": "/dst", "type": "", "source": dst,
                      "options": ["rbind"]})
io.open(work + "/config.json", "w", encoding="utf-8").write(json.dumps(cfg, indent=2) + "\n")
PY

./cosmos-rt --bundle "$WORK" --limit-mb 2048 --build 1 --quiet 1
rm -rf "$WORK"
