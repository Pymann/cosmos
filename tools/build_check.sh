#!/usr/bin/env bash
# build_check.sh <config> — baut und prueft den RUECKGABEWERT, nicht ein Grep-Muster.
#
# Zwei Fallen, beide am 17.10.2026 selbst hineingetreten:
#
# 1. `build | grep "error:"` findet `[ERROR] ... variable name 'u0' is shorter`
#    NICHT.  Der Build schlug fehl, der Check sah sauber aus, und danach lief ein ALTES
#    Binary, das PASS sagte.  Ein Build-Check, der den Exit-Code ignoriert, prueft nichts.
#
# 2. Nach einem FEHLGESCHLAGENEN Compile linkte exodus beim naechsten Lauf mit den ALTEN
#    Objekten.  `aiml build` (aiml spec/68 §7) leert out/<ziel>/ vor jedem Bau, die Falle
#    gibt es damit nicht mehr.
set -uo pipefail
cd "$(dirname "$0")/.."
# aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
# venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
[ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
out=$(aiml build -c "$1" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
    echo "BUILD FAILED ($1) rc=$rc"
    echo "$out" | grep -E "\[ERROR\]|error:" | head -6
    exit 1
fi
echo "build ok: $1"
