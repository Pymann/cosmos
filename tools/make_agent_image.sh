#!/usr/bin/env bash
# Ein AGENTEN-ABBILD: ein echtes Ubuntu, in dem der Agent wohnt.
#
#   tools/make_agent_image.sh [basis] [ziel]
#
# Der Unterschied zur Vorlage (tools/make_rt_template.sh): die Vorlage traegt
# NUR den Agenten und borgt sich /usr vom Wirt.  Dieses Abbild bringt sein
# eigenes Betriebssystem mit — und genau das braucht eine Bau-Pipeline, die
# `apt-get install` sagt: sie veraendert ihre WURZEL, und die muss ihr gehoeren.
#
# Der Agent liegt unter /opt/cosmos, nicht in /usr: eine Distribution, in die
# man fremde Bibliotheken streut, ist keine Distribution mehr (gemessen: 10 von
# 50 Dateien kollidierten mit /usr/lib/x86_64-linux-gnu).
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:-deploy/rt_base}"
OUT="${2:-deploy/rt_image}"
[ -d "$BASE" ]                   || { echo "FEHLER: $BASE fehlt — tools/make_base_rootfs.sh" >&2; exit 1; }
[ -f deploy/runtime.tar.gz ]     || { echo "FEHLER: deploy/runtime.tar.gz fehlt — deploy/collect_runtime.sh" >&2; exit 1; }
[ -f agent ]                     || { echo "FEHLER: ./agent fehlt — aiml build -c exodus-agent.json" >&2; exit 1; }

rm -rf "$OUT"
cp -a "$BASE" "$OUT"
mkdir -p "$OUT/opt/cosmos"
tar xzf deploy/runtime.tar.gz -C "$OUT/opt/cosmos"
cp agent "$OUT/opt/cosmos/agent"
# Bind-Ziele muessen existieren — auch Dateien.  ubuntu-base bringt ein LEERES
# /dev mit; die Geraete reicht der Wirt hinein (F110-45).
mkdir -p "$OUT/work" "$OUT/src" "$OUT/proc" "$OUT/dev" "$OUT/ws"
for d in null zero full random urandom tty; do : > "$OUT/dev/$d"; done
# apt braucht seine Arbeitsverzeichnisse; im Tarball fehlen die leeren Ordner
# (gemessen: „List directory /var/lib/apt/lists/partial is missing").
mkdir -p "$OUT/var/lib/apt/lists/partial" "$OUT/var/cache/apt/archives/partial" \
         "$OUT/var/lib/dpkg/updates" "$OUT/var/log/apt" "$OUT/run/lock"
: > "$OUT/token"
: > "$OUT/gitcred"
chmod 600 "$OUT/token"
# Namensaufloesung: in der Basis ist /etc/resolv.conf oft ein toter Symlink.
rm -f "$OUT/etc/resolv.conf"
cp -L /etc/resolv.conf "$OUT/etc/resolv.conf" 2>/dev/null || printf 'nameserver 1.1.1.1\n' > "$OUT/etc/resolv.conf"
echo "Abbild: $OUT ($(du -sh "$OUT" | cut -f1), $(find "$OUT" -type f | wc -l) Dateien)"
