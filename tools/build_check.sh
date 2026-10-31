#!/usr/bin/env bash
# build_check.sh <config> — baut und prueft den RUECKGABEWERT, nicht ein Grep-Muster.
#
# Zwei Fallen, beide am 17.10.2026 selbst hineingetreten:
#
# 1. `exodus build | grep "error:"` findet `[ERROR] ... variable name 'u0' is shorter`
#    NICHT.  Der Build schlug fehl, der Check sah sauber aus, und danach lief ein ALTES
#    Binary, das PASS sagte.  Ein Build-Check, der den Exit-Code ignoriert, prueft nichts.
#
# 2. Nach einem FEHLGESCHLAGENEN Compile meldet der naechste Lauf "up to date, skipping
#    compilation" und linkt mit den ALTEN Objekten — Exit-Code 0, obwohl die Aenderung
#    nicht drin ist.  Erkennbar an "excluding N unexpected AIML object(s) not referenced
#    by depfiles": genau die neuen Dateien fehlen dann im Link.  Darum ist diese Warnung
#    hier ein FEHLER, kein Hinweis.  Heilmittel: `rm -rf out/<ziel>` und neu bauen.
set -uo pipefail
cd "$(dirname "$0")/.."
# In einem Container liegt exodus woanders und steht schon auf PATH.
[ -f ../../exvenv/bin/activate ] && source ../../exvenv/bin/activate
# aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
# venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
[ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
out=$(exodus build -c "$1" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
    echo "BUILD FAILED ($1) rc=$rc"
    echo "$out" | grep -E "\[ERROR\]|error:" | head -6
    exit 1
fi
# Die Warnung hat ZWEI Ursachen, und nur eine ist gefaehrlich:
#   (a) Altlasten geloeschter Quellen im Ausgabeverzeichnis — harmlos.
#   (b) NEUE Dateien, die der Link auslaesst, weil die Depfiles von einem
#       fehlgeschlagenen Compile stammen — genau das kostete am 17.10. zwei falsche
#       "build ok".
# Unterscheiden laesst es sich daran, ob zu einem ausgeschlossenen Objekt noch eine
# QUELLE existiert.  Statt zu raten: einmal aufraeumen und neu bauen.  Das ist billig
# und macht den Unterschied gegenstandslos.
if echo "$out" | grep -q "excluding .* unexpected AIML object"; then
    tgt=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$1" 2>/dev/null)
    if [ -n "$tgt" ] && [ -d "out/$tgt" ]; then
        echo "  (Objekt-Scan unstimmig — out/$tgt wird einmal aufgeraeumt und neu gebaut)"
        rm -rf "out/$tgt"
        out=$(exodus build -c "$1" 2>&1); rc=$?
        if [ $rc -ne 0 ]; then
            echo "BUILD FAILED ($1) nach Aufraeumen rc=$rc"
            echo "$out" | grep -E "\[ERROR\]|error:" | head -6
            exit 1
        fi
    fi
fi
echo "build ok: $1"
