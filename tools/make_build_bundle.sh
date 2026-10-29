#!/usr/bin/env bash
# Baut ein Bundle, in dem WIRKLICH gebaut werden kann (doc/spec/110 §110.23):
# schreibbare Wurzel, Netz, Namensaufloesung, echte Distribution.
#
#   tools/make_build_bundle.sh <name> '<shell-befehl>'
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?Name fehlt}"
CMD="${2:?Befehl fehlt}"
# Optional: ein Verzeichnis des Hosts schreibgeschuetzt hineinreichen,
# z.B. ein Git-Repository als Quelle (`/pfad/auf/host:/pfad/im/container`).
EXTRA="${3:-}"
BASE="${RT_BASE:-deploy/rt_base}"
OUT="logs/rt_builds/$NAME"
[ -d "$BASE" ] || { echo "FEHLER: $BASE fehlt — tools/make_base_rootfs.sh" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
# Ohne overlay: kopieren.  Der Vertrag ist der Baum, nicht das Mittel (F110-12);
# mit overlay waere dies ein Mount statt einer Kopie.
# Ein CUT traegt ein Manifest — seine Dateien gehoeren abgebildeten Kennungen
# und sind von aussen nicht lesbar.  Dann kopiert ein Container (§110.24).
if [ -f "$BASE.manifest" ]; then
  ./tools/materialize.sh "$BASE" "$OUT/rootfs"
else
  cp -a "$BASE" "$OUT/rootfs"
fi
# Namensaufloesung: in der Vorlage ist /etc/resolv.conf oft ein Symlink ins
# Leere (systemd-resolved).  Eine echte Datei statt eines Binds auf einen
# toten Link.
rm -f "$OUT/rootfs/etc/resolv.conf"
cp -L /etc/resolv.conf "$OUT/rootfs/etc/resolv.conf" 2>/dev/null || \
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$OUT/rootfs/etc/resolv.conf"
# Die ueblichen Geraete: ohne /dev/urandom stirbt apts HTTP-Helfer mit
# „Method http has died unexpectedly" (gemessen).  Ohne root kein mknod, also
# werden die Geraete des Hosts hineingebunden — Ziele muessen existieren.
for d in null zero full random urandom tty; do : > "$OUT/rootfs/dev/$d"; done

python3 - "$OUT" "$CMD" "$NAME" "$EXTRA" <<'PY'
import json, sys, io
out, cmd, name = sys.argv[1], sys.argv[2], sys.argv[3]
extra = sys.argv[4] if len(sys.argv) > 4 else ""

cfg = {
  "ociVersion": "1.0.2",
  "process": {
    "terminal": False,
    "user": {"uid": 0, "gid": 0},
    "args": ["/bin/sh", "-lc", cmd],
    "env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "HOME=/root", "TERM=dumb", "LC_ALL=C",
      "DEBIAN_FRONTEND=noninteractive",
    ],
    "cwd": "/",
    "noNewPrivileges": True,
  },
  # SCHREIBBAR — das ist der Unterschied zum Agenten-Container.
  "root": {"path": "rootfs", "readonly": False},
  "hostname": name,
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc", "options": []},
    {"destination": "/dev/null", "type": "", "source": "/dev/null", "options": ["bind"]},
    {"destination": "/dev/zero", "type": "", "source": "/dev/zero", "options": ["bind"]},
    {"destination": "/dev/full", "type": "", "source": "/dev/full", "options": ["bind"]},
    {"destination": "/dev/random", "type": "", "source": "/dev/random", "options": ["bind"]},
    {"destination": "/dev/urandom", "type": "", "source": "/dev/urandom", "options": ["bind"]},
    {"destination": "/dev/tty", "type": "", "source": "/dev/tty", "options": ["bind"]},
    {"destination": "/tmp", "type": "tmpfs", "source": "tmpfs",
     "options": ["nosuid", "nodev", "mode=1777"]},
  ],
  "linux": {
    "namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "user"},
                   {"type": "ipc"}, {"type": "uts"}],
    "maskedPaths": ["/proc/sysrq-trigger"],
    "readonlyPaths": [],
  },
}
if extra:
    src, dst = extra.split(":", 1)
    import os
    os.makedirs(out + "/rootfs" + dst, exist_ok=True)
    cfg["mounts"].append({"destination": dst, "type": "", "source": src,
                          "options": ["rbind", "ro"]})
io.open(out + "/config.json", "w", encoding="utf-8").write(json.dumps(cfg, indent=2) + "\n")
PY
echo "Bundle: $OUT ($(du -sh "$OUT" | cut -f1))"
