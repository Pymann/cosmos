#!/usr/bin/env bash
# Abnahme C5 (doc/spec/92 §92.7): CAS darf grosse Inhalte nicht im
# Arbeitsspeicher halten.
#
# Messverfahren wie §AP1.5a / run_mem_check.sh: ZWEI Durchläufe mit
# unterschiedlich grossen Dateien.  Entscheidend ist nicht der absolute
# Spitzen-RSS (Allocator-Arenen, Laufzeit-Grundlast, AionDB = fixe Grundlast),
# sondern ob er MIT DER DATEIGRÖSSE SKALIERT.  Würde put_tree oder materialize
# die Datei puffern, müsste der grosse Lauf die Grössendifferenz zusätzlich
# belegen.
#
# Gemessen wird der Spitzenwert (`/usr/bin/time -f %M` = rusage.ru_maxrss), nicht
# der momentane RSS: ein Puffer, der vor Prozessende freigegeben wird, bleibt im
# momentanen Wert unsichtbar.
#
#   ./run_cas_mem_check.sh              # 20 MB gegen 220 MB
#   SMALL_MB=10 BIG_MB=400 ./run_cas_mem_check.sh
#   ./run_cas_mem_check.sh --run-only   # nicht neu bauen
#
# Logs in logs/ (persistent).  Die Testdaten liegen unter /tmp (gross, flüchtig)
# und werden am Ende entfernt.
set -uo pipefail
cd "$(dirname "$0")"

SMALL_MB="${SMALL_MB:-20}"
BIG_MB="${BIG_MB:-220}"
WORK="/tmp/cosmos_cas_mem_check"
LOGS="$PWD/logs"
mkdir -p "$LOGS"

if [ "${1:-}" != "--run-only" ]; then
    # shellcheck disable=SC1091
    # In einem Container liegt exodus woanders und steht schon auf PATH.
    [ -f ../../exvenv/bin/activate ] && source ../../exvenv/bin/activate
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    echo "=== building exodus-test-casmem.json ==="
    exodus build -c exodus-test-casmem.json || { echo "BUILD FAILED"; exit 1; }
fi
[ -x ./test_cas_mem ] || { echo "missing ./test_cas_mem — ohne --run-only starten"; exit 1; }

cleanup() { rm -rf "$WORK" /dev/shm/cosmos_cas_mem_src; }
trap cleanup EXIT

# Ein Lauf: Datei der gewünschten Grösse erzeugen, Probe unter /usr/bin/time
# fahren, Spitzen-RSS in KB zurückgeben.
run_one() {
    local mb="$1" tag="$2" srcbase="${3:-$WORK}" casbase="${4:-$WORK}"
    rm -rf "$WORK" "$srcbase" "$casbase"
    mkdir -p "$srcbase/src" "$casbase/cas" "$casbase/out"
    # Zufallsdaten, damit nichts komprimiert oder dedupliziert wird und die
    # beiden Läufe nicht denselben Blob treffen.
    head -c "$((mb * 1024 * 1024))" /dev/urandom > "$srcbase/src/payload.bin"

    mkdir -p "$WORK"
    local tf="$WORK/time.txt"
    COSMOS_CAS_DIR="$srcbase/src" COSMOS_CAS_ROOT="$casbase/cas" COSMOS_CAS_OUT="$casbase/out" \
        /usr/bin/time -f "%M" -o "$tf" ./test_cas_mem > "$LOGS/cas_mem_$tag.log" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  Lauf $tag FEHLGESCHLAGEN (rc=$rc):" >&2
        tail -5 "$LOGS/cas_mem_$tag.log" >&2
        return 1
    fi
    tail -1 "$tf"
}

# ── Phase 1: Quelle auf demselben Dateisystem wie der Store ─────────────────
# Seit Befund 1 (doc/spec/92 §92.5) kopieren put_file UND materialize immer —
# Hardlinks sind weg, weil sie die Inode mit Quelle bzw. Ziel teilten.  Dadurch
# messen beide Phasen denselben Code-Pfad; sie unterscheiden sich nur noch
# darin, WO die Quelle liegt.  Beides zu messen bleibt sinnvoll (ein Quell-
# Dateisystem mit anderem Blockverhalten ist ein realistischer Fall), aber die
# ursprüngliche Begründung "Phase 2 erzwingt den Kopierpfad" ist entfallen.
echo "=== C5 Phase 1 (Quelle am selben Dateisystem): ${SMALL_MB} MB gegen ${BIG_MB} MB ==="
PEAK_SMALL=$(run_one "$SMALL_MB" small) || exit 1
echo "  ${SMALL_MB} MB → Spitzen-RSS ${PEAK_SMALL} kB"
PEAK_BIG=$(run_one "$BIG_MB" big) || exit 1
echo "  ${BIG_MB} MB → Spitzen-RSS ${PEAK_BIG} kB"

DIFF_MB=$((BIG_MB - SMALL_MB))
GROWTH_KB=$((PEAK_BIG - PEAK_SMALL))
# Schwelle: der Zuwachs darf höchstens 10 % der Grössendifferenz sein.  Würde
# der Inhalt gepuffert, lägen es ~100 %.  10 % lässt Arena-Rauschen zu, ohne
# einen echten Puffer durchzulassen.
BUDGET_KB=$(( DIFF_MB * 1024 / 10 ))

echo "  Differenz der Dateigrössen: ${DIFF_MB} MB"
echo "  Zuwachs Spitzen-RSS:        ${GROWTH_KB} kB (Budget ${BUDGET_KB} kB)"
FAILED=0
if [ "$GROWTH_KB" -le "$BUDGET_KB" ]; then
    echo "  [Phase 1] PASS — Spitzen-RSS skaliert nicht mit der Dateigrösse"
else
    echo "  [Phase 1] FAIL — Spitzen-RSS wuchs um ${GROWTH_KB} kB bei ${DIFF_MB} MB mehr Inhalt"
    FAILED=1
fi

# ── Phase 2: Quelle auf tmpfs, Store auf der Platte ─────────────────────────
# Früher der entscheidende Fall (er erzwang den Kopierpfad gegen den Hardlink);
# seit Befund 1 wird immer kopiert, also ist es nur noch eine zweite
# Quell-Umgebung.  Behalten, weil es nichts kostet und tmpfs anders puffert.
SHM_SRC="/dev/shm/cosmos_cas_mem_src"
if [ ! -d /dev/shm ]; then
    echo "  [Phase 2] ÜBERSPRUNGEN — kein /dev/shm (kein zweites Dateisystem verfügbar)"
else
    echo "=== C5 Phase 2 (Quelle auf tmpfs): ${SMALL_MB} MB gegen ${BIG_MB} MB ==="
    PEAK_X_SMALL=$(run_one "$SMALL_MB" xsmall "$SHM_SRC" "$WORK") || exit 1
    echo "  ${SMALL_MB} MB → Spitzen-RSS ${PEAK_X_SMALL} kB"
    PEAK_X_BIG=$(run_one "$BIG_MB" xbig "$SHM_SRC" "$WORK") || exit 1
    echo "  ${BIG_MB} MB → Spitzen-RSS ${PEAK_X_BIG} kB"
    rm -rf "$SHM_SRC"

    GROWTH_X_KB=$((PEAK_X_BIG - PEAK_X_SMALL))
    echo "  Zuwachs Spitzen-RSS:        ${GROWTH_X_KB} kB (Budget ${BUDGET_KB} kB)"
    if [ "$GROWTH_X_KB" -le "$BUDGET_KB" ]; then
        echo "  [Phase 2] PASS — auch mit Quelle auf tmpfs kein Puffer"
    else
        echo "  [Phase 2] FAIL — copy_blocks puffert (Zuwachs ${GROWTH_X_KB} kB)"
        FAILED=1
    fi
fi

echo "========================================================"
if [ "$FAILED" -eq 0 ]; then
    echo "[C5] PASS — Spitzen-RSS skaliert auf BEIDEN Pfaden nicht mit der Dateigrösse"
    exit 0
fi
echo "[C5] FAIL — siehe Phasen oben"
exit 1
