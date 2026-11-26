#!/usr/bin/env bash
# Abnahmekriterium 10(b) (doc/spec/90 §AP1.5a): der Server darf die Ausgabe NICHT
# akkumulieren.
#
# Messmethode: ZWEI Durchläufe gegen DENSELBEN cosmosd — einer mit kleiner, einer
# mit grosser Ausgabe.  Entscheidend ist nicht der absolute RSS-Zuwachs (Allocator-
# Arenen, AionDB, erste Dispatch-Pfade = fixe Grundlast), sondern ob der Zuwachs
# MIT DER AUSGABELÄNGE SKALIERT.  Würde der Server die Ausgabe halten, müsste der
# grosse Durchlauf die Differenz der Ausgabegrössen zusätzlich belegen.
# Logs in logs/ (persistent).
set -uo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8801}"
SMALL="${SMALL:-seq 1 20000}"          # ~0,1 MB
# ~39 MB.  Bis 2026-11-26 ~6,9 MB: die Grenze (1/8 davon, ~830 kB) lag UNTER dem
# Rauschen der Allokator-Arenen, das unabhaengig von der Ausgabe 0 oder ~1,2 MB
# betraegt — derselbe Stand fiel in 2 von 4 Laeufen durch.  Bei 39 MB liegt die
# Grenze bei ~4,7 MB: das Rauschen bleibt darunter, eine echte Akkumulation (39 MB)
# weit darueber.
BIG="${BIG:-seq 1 5000000}"
URL="ws://127.0.0.1:${PORT}"
WORK="$PWD/.mem_run"
LOGS="$PWD/logs"

for bin in cosmosd agent e2e_agent_exec e2e_enroll; do
    [ -x "./$bin" ] || { echo "missing ./$bin — build first (./run_e2e.sh)"; exit 1; }
done

mkdir -p "$LOGS"
rm -rf "$WORK"
mkdir -p "$WORK"
cp cosmosd agent e2e_agent_exec e2e_enroll "$WORK/"

DAEMON_PID=""
AGENT_PID=""
cleanup() {
    [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

rss_kb() { awk '/VmRSS/ {print $2}' "/proc/$1/status" 2>/dev/null; }
biggest_out() { stat -c %s "$WORK"/run_logs/*.out 2>/dev/null | sort -n | tail -1; }

cd "$WORK"
export AIONDB_PATH="$WORK/aiondb"

COSMOS_BIND="$URL" ./cosmosd > "$LOGS/mem_cosmosd.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do
    grep -q "listening on" "$LOGS/mem_cosmosd.log" 2>/dev/null && break
    sleep 0.2
done

# Agent-Token wie im Web-UI erzeugen (§AP1.9); das Geheimnis wird nicht geloggt.
AGENT_TOKEN=$(COSMOS_E2E_URL="$URL" ./e2e_enroll 2>"$LOGS/mem_enroll.log")
if [ -z "$AGENT_TOKEN" ]; then
    echo "[mem] FAIL — Token-Erzeugung fehlgeschlagen"; tail -10 "$LOGS/mem_enroll.log"; exit 1
fi

# 4 Läufe: je Client-Durchlauf ein kleiner + ein "grosser"
COSMOS_AGENT_TOKEN="$AGENT_TOKEN" ./agent --exec-url "$URL" --agent-id agent-e2e --stop-after 4 > "$LOGS/mem_agent.log" 2>&1 &
AGENT_PID=$!
sleep 1

echo "[mem] cosmosd RSS at start: $(rss_kb "$DAEMON_PID") kB"

echo "[mem] pass 1 — small output: $SMALL"
COSMOS_E2E_URL="$URL" COSMOS_E2E_BIG="$SMALL" ./e2e_agent_exec > "$LOGS/mem_client_small.log" 2>&1
RC_SMALL=$?
RSS_SMALL=$(rss_kb "$DAEMON_PID")
OUT_SMALL=$(biggest_out)
echo "[mem]   RSS after small: ${RSS_SMALL} kB   (stored ${OUT_SMALL} B)"

echo "[mem] pass 2 — big output: $BIG"
COSMOS_E2E_URL="$URL" COSMOS_E2E_BIG="$BIG" ./e2e_agent_exec > "$LOGS/mem_client_big.log" 2>&1
RC_BIG=$?
RSS_BIG=$(rss_kb "$DAEMON_PID")
OUT_BIG=$(biggest_out)
echo "[mem]   RSS after big:   ${RSS_BIG} kB   (stored ${OUT_BIG} B)"

echo "========================================================"
if [ "$RC_SMALL" -ne 0 ] || [ "$RC_BIG" -ne 0 ]; then
    echo "[mem] FAIL — e2e client failed (small=$RC_SMALL big=$RC_BIG)"
    tail -20 "$LOGS/mem_client_big.log"
    exit 1
fi

MARGIN_KB=$(( RSS_BIG - RSS_SMALL ))
EXTRA_KB=$(( (OUT_BIG - OUT_SMALL) / 1024 ))
# Hielte der Server die Ausgabe, müsste er EXTRA_KB zusätzlich belegen.
# Schwelle: ein Achtel davon (mind. 512 kB Toleranz für Fragmentierung).
LIMIT_KB=$(( EXTRA_KB / 8 ))
[ "$LIMIT_KB" -lt 512 ] && LIMIT_KB=512

echo "[mem] zusätzliche Ausgabe: ${EXTRA_KB} kB"
echo "[mem] zusätzlicher RSS:    ${MARGIN_KB} kB   (Grenze ${LIMIT_KB} kB)"
if [ "$MARGIN_KB" -lt "$LIMIT_KB" ]; then
    echo "[mem] PASS — RSS skaliert NICHT mit der Ausgabelänge (keine Akkumulation)"
    exit 0
fi
echo "[mem] FAIL — RSS wächst mit der Ausgabe → der Server hält sie (Akkumulation!)"
exit 1
