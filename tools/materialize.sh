#!/usr/bin/env bash
# Einen Cut als Arbeits-rootfs bereitstellen (doc/spec/110 §110.24).
#
#   tools/materialize.sh <cut-verzeichnis> <ziel-verzeichnis>
#
# Die Kopie laeuft IM NAMESPACE — aus demselben Grund wie der Cut selbst:
# Dateien unter abgebildeten Kennungen (`_apt` & Co.) sind von aussen nicht
# lesbar.  Wer einen ID-Bereich abbildet, muss ALLES, was diese Dateien
# anfasst, in derselben Abbildung tun.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(cd "${1:?Quelle fehlt}" && pwd)"
DSTDIR="${2:?Ziel fehlt}"
mkdir -p "$(dirname "$DSTDIR")"
PARENT="$(cd "$(dirname "$DSTDIR")" && pwd)"
LEAF="$(basename "$DSTDIR")"

WORK="logs/rt_builds/.mat-$LEAF"
RT_BASE=deploy/rt_base ./tools/make_build_bundle.sh ".mat-$LEAF" '
set -e
rm -rf "/dst/'"$LEAF"'"
cp -a /src "/dst/'"$LEAF"'"
' "$SRC:/src" >/dev/null

python3 - "$WORK" "$PARENT" <<'PY'
import json, io, sys, os
work, dst = sys.argv[1], sys.argv[2]
cfg = json.load(io.open(work + "/config.json", encoding="utf-8"))
os.makedirs(work + "/rootfs/dst", exist_ok=True)
cfg["mounts"].append({"destination": "/dst", "type": "", "source": dst, "options": ["rbind"]})
io.open(work + "/config.json", "w", encoding="utf-8").write(json.dumps(cfg, indent=2) + "\n")
PY

./cosmos-rt --bundle "$WORK" --limit-mb 2048 --build 1 --quiet 1
rm -rf "$WORK"
