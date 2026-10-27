#!/usr/bin/env bash
# Baut die rootfs-VORLAGE, die sich alle Container-Agenten teilen
# (doc/spec/110 §110.17).  Ein Abbild je Lauf zu kopieren waere Platz und Zeit
# fuer nichts — nur das Token unterscheidet die Laeufe, und das reist als
# eigener Bind hinein.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-deploy/rt_template}"
[ -f deploy/runtime.tar.gz ] || { echo "FEHLER: deploy/runtime.tar.gz fehlt — erst deploy/collect_runtime.sh" >&2; exit 1; }
[ -f agent ] || { echo "FEHLER: ./agent fehlt — erst exodus build -c exodus-agent.json" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"/{usr/bin,usr/lib,usr/lib64,proc,dev,tmp,work,etc,run/systemd/resolve}
tar xzf deploy/runtime.tar.gz -C "$OUT"/
cp agent "$OUT"/agent
# Merged-usr spiegeln statt wegbinden (F110-31): ein Bind auf /lib64 zerreisst
# die relativen Symlinks des Laders.
ln -sfn usr/bin   "$OUT"/bin
ln -sfn usr/lib64 "$OUT"/lib64
# Bind-Ziele muessen EXISTIEREN — auch fuer Dateien.
for d in null zero full random urandom tty; do : > "$OUT"/dev/$d; done
# Bind-Ziel fuer eine optionale git-Zugangsdatei (COSMOS_RT_GIT_CRED).
: > "$OUT"/gitcred
mkdir -p "$OUT"/src     # Bind-Ziel fuer lokale Spiegel (COSMOS_RT_SRC)
: > "$OUT"/token
chmod 600 "$OUT"/token
echo "Vorlage: $OUT ($(du -sh "$OUT" | cut -f1), $(find "$OUT" -type f | wc -l) Dateien)"
