#!/usr/bin/env bash
# Entpackt das Basis-rootfs, auf dem gebaut wird (doc/spec/110 §110.23).
#
# Es ist die VORLAGE: unveraendert, fuer alle Baulaeufe dieselbe.  Jeder Lauf
# bekommt eine eigene Kopie — solange es kein overlay gibt (auf diesem Rechner
# ist das Modul nicht geladen und unprivilegiert nicht nachladbar, F110-12).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-deploy/base_ubuntu.tar.xz}"
OUT="${2:-deploy/rt_base}"
[ -f "$SRC" ] || { echo "FEHLER: $SRC fehlt" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
# Ohne --numeric-owner wuerde tar Namen aufloesen, die es hier nicht gibt.
# Fehler bei Geraetedateien sind erwartbar (ohne root kein mknod) und kein Grund
# aufzuhoeren — die braucht der Build nicht, /dev/null wird gebunden.
tar --numeric-owner -xf "$SRC" -C "$OUT" 2>/dev/null || true
mkdir -p "$OUT"/{proc,sys,dev,tmp,run}
: > "$OUT/dev/null" 2>/dev/null || true
echo "Vorlage: $OUT ($(du -sh "$OUT" | cut -f1), $(find "$OUT" -maxdepth 1 -mindepth 1 | wc -l) Eintraege)"
