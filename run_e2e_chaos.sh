#!/usr/bin/env bash
# Robustheit: ueberlebt ein Lauf einen Server-Neustart und einen
# Agenten-Neustart MITTEN in der Arbeit?
#
# Das war nie geprueft.  Geprueft wurde der Gutfall; die Frage des Nutzers
# (2026-10-15) ist aber der Schlechtfall: „der Agent muss danach wieder da
# sein, die Pipeline muss ueberleben".
#
#   Fall A: cosmosd stirbt waehrend eines Laufs und kommt wieder
#   Fall B: der Agent stirbt waehrend eines Laufs und kommt wieder
#   Fall C: der Agent stirbt mitten im Schritt (der Schritt laeuft weiter)
#   Fall D: der RECHNER startet neu — Agent UND Schritt sind weg
#
# In beiden Faellen MUSS der Lauf zu Ende kommen.
set -uo pipefail
cd "$(dirname "$0")"
PORT="${PORT:-8803}"
URL="ws://127.0.0.1:${PORT}"
# Der Sandkasten (doc/spec/91), wie in run_e2e_pipeline.sh.
BWRAP="${COSMOS_BWRAP:-$(command -v bwrap || echo /opt/cosmos/bwrap)}"
[ -x "$BWRAP" ] || { echo "[chaos] FAIL — kein bwrap (apt install bubblewrap, oder COSMOS_BWRAP)"; exit 1; }
WORK="$PWD/.e2e_chaos"
LOGS="$PWD/logs"

if [ "${1:-}" != "--run-only" ]; then
    # shellcheck disable=SC1091
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    for cfg in exodus-cosmosd.json exodus-agent.json exodus-test-enroll.json exodus-test-e2epipe.json; do
        aiml build -c "$cfg" || { echo "BUILD FAILED: $cfg"; exit 1; }
    done
fi
for bin in cosmosd agent e2e_enroll e2e_pipeline_run; do
    [ -x "./$bin" ] || { echo "missing ./$bin"; exit 1; }
done

mkdir -p "$LOGS"; rm -rf "$WORK"; mkdir -p "$WORK"
cp cosmosd agent e2e_enroll e2e_pipeline_run "$WORK/"
DPID=""; APID=""
cleanup() { [ -n "$APID" ] && kill "$APID" 2>/dev/null; [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT
cd "$WORK"
export AIONDB_PATH="$WORK/aiondb"

start_server() {
    COSMOS_BIND="$URL" ./cosmosd >> "$LOGS/e2echaos_cosmosd.log" 2>&1 &
    DPID=$!
    for _ in $(seq 1 60); do
        grep -q "listening on" "$LOGS/e2echaos_cosmosd.log" 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}
start_agent() {
    COSMOS_AGENT_TOKEN="$TOKEN" ./agent --exec-url "$URL" --agent-id agent-e2e --labels e2e --bwrap-path "$BWRAP" \
        >> "$LOGS/e2echaos_agent.log" 2>&1 &
    APID=$!
}

: > "$LOGS/e2echaos_cosmosd.log"; : > "$LOGS/e2echaos_agent.log"
start_server || { echo "[chaos] cosmosd startet nicht"; exit 1; }
TOKEN=$(COSMOS_E2E_URL="$URL" ./e2e_enroll 2>"$LOGS/e2echaos_enroll.log")
[ -n "$TOKEN" ] || { echo "[chaos] kein Token"; exit 1; }
start_agent
echo "[chaos] Server $DPID, Agent $APID"

FAILED=0

# ── Fall A: der SERVER geht mitten im Lauf weg ───────────────────────────
echo "[chaos] Fall A: cosmosd mitten im Lauf neu starten"
COSMOS_E2E_URL="$URL" ./e2e_pipeline_run > "$LOGS/e2echaos_runA.log" 2>&1 &
CLIENT=$!
sleep 4                      # der Lauf ist angelaufen
kill -9 "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
echo "[chaos]   cosmosd getoetet — 3 s Pause"
sleep 3
start_server || { echo "[chaos] cosmosd kommt nicht wieder"; exit 1; }
echo "[chaos]   cosmosd wieder da ($DPID)"
wait "$CLIENT"; RA=$?
if [ "$RA" -eq 0 ]; then echo "[chaos] ok   Fall A: der Lauf ueberlebt den Server-Neustart"
else echo "[chaos] FAIL Fall A (rc=$RA)"; tail -12 "$LOGS/e2echaos_runA.log"; FAILED=$((FAILED+1)); fi

# ── Fall B: der AGENT geht mitten im Lauf weg ────────────────────────────
echo "[chaos] Fall B: Agent mitten im Lauf neu starten"
COSMOS_E2E_URL="$URL" ./e2e_pipeline_run > "$LOGS/e2echaos_runB.log" 2>&1 &
CLIENT=$!
sleep 4
kill -9 "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
echo "[chaos]   Agent getoetet — 2 s Pause"
sleep 2
start_agent
echo "[chaos]   Agent wieder da ($APID)"
wait "$CLIENT"; RB=$?
if [ "$RB" -eq 0 ]; then echo "[chaos] ok   Fall B: der Lauf ueberlebt den Agenten-Neustart"
else echo "[chaos] FAIL Fall B (rc=$RB)"; tail -12 "$LOGS/e2echaos_runB.log"; FAILED=$((FAILED+1)); fi

# ── Fall C: der Agent stirbt MITTEN im Schritt ───────────────────────────
# Der Schritt laeuft abgekoppelt weiter (eigene Sitzung und Prozessgruppe,
# spec/23 §5.4).  Der neu gestartete Agent MUSS ihn wieder aufnehmen und sein
# Ergebnis melden — nicht noch einmal ausfuehren.  Gemessen wird genau das:
# wie oft eine Stufe gestartet wurde.
echo "[chaos] Fall C: Agent waehrend eines LAUFENDEN Schritts toeten"
: > "$LOGS/e2echaos_agentC.log"
kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
COSMOS_AGENT_TOKEN="$TOKEN" ./agent --exec-url "$URL" --agent-id agent-e2e --labels e2e --bwrap-path "$BWRAP" \
    >> "$LOGS/e2echaos_agentC.log" 2>&1 &
APID=$!
COSMOS_STEP_SLEEP=6 COSMOS_E2E_URL="$URL" ./e2e_pipeline_run > "$LOGS/e2echaos_runC.log" 2>&1 &
CLIENT=$!
sleep 6                      # die erste Stufe schlaeft gerade
kill -9 "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
echo "[chaos]   Agent im Schritt getoetet"
sleep 1
COSMOS_AGENT_TOKEN="$TOKEN" ./agent --exec-url "$URL" --agent-id agent-e2e --labels e2e --bwrap-path "$BWRAP" \
    >> "$LOGS/e2echaos_agentC.log" 2>&1 &
APID=$!
echo "[chaos]   Agent wieder da ($APID)"
wait "$CLIENT"; RC=$?
STARTS=$(grep -c 'gestartet (pid' "$LOGS/e2echaos_agentC.log" || true)
RESUMED=$(grep -c 'laeuft noch\|war fertig, Rueckgabewert' "$LOGS/e2echaos_agentC.log" || true)
if [ "$RC" -eq 0 ]; then echo "[chaos] ok   Fall C: der Lauf kommt zu Ende"
else echo "[chaos] FAIL Fall C (rc=$RC)"; tail -12 "$LOGS/e2echaos_runC.log"; FAILED=$((FAILED+1)); fi
if [ "$RESUMED" -ge 1 ]; then echo "[chaos] ok   Fall C: der Schritt wurde WIEDER AUFGENOMMEN ($RESUMED)"
else echo "[chaos] FAIL Fall C: keine Wiederaufnahme — der Schritt lief neu"; FAILED=$((FAILED+1)); fi
# Drei Stufen, also drei Starts.  Mehr hiesse: etwas lief doppelt.
# Soviele Starts wie Stufen — mehr hiesse: etwas lief doppelt.  Die Zahl wird
# aus der Probe-Pipeline GEZAEHLT, nicht hier wiederholt: als sie fest „3"
# war, meldete die Abnahme eine Doppelausfuehrung, nachdem die Pipeline eine
# vierte Stufe bekam (2026-10-15).
# Nur die Stufen der PROBE-Pipeline, nicht die der Zeitgrenzen-Probe daneben.
STAGES=$(awk '/name: probe_source/,/return: src/' ../test/e2e_pipeline_run.aiml | grep -c "stage:")
if [ "$STARTS" -le "$STAGES" ]; then echo "[chaos] ok   Fall C: keine Doppelausfuehrung ($STARTS Starts fuer $STAGES Stufen)"
else echo "[chaos] FAIL Fall C: $STARTS Starts fuer $STAGES Stufen — etwas lief doppelt"; FAILED=$((FAILED+1)); fi

# ── Fall C, zweiter Teil: die Ausgabe nach dem Neustart ─────────────────
# Die gesendeten Offsets stehen in der Schritt-Ablage (doc/spec/103 §103.4e).
# Gingen sie verloren, schickte der neu gestartete Agent von vorn — im
# Server-Protokoll stuende dann dieselbe Zeile zweimal.  Genau das wird gezaehlt.
DUPES=$(grep -ch "stufe-eins" run_logs/*-0-0.out 2>/dev/null | sort -rn | head -1)
[ -n "$DUPES" ] || DUPES=0
if [ "$DUPES" -eq 1 ]; then echo "[chaos] ok   Fall C: Ausgabe nach dem Neustart genau einmal (Offsets ueberlebten)"
elif [ "$DUPES" -eq 0 ]; then echo "[chaos] FAIL Fall C: keine Ausgabe im Server-Protokoll"; FAILED=$((FAILED+1))
else echo "[chaos] FAIL Fall C: Ausgabe ${DUPES}x im Protokoll — die Offsets gingen verloren"; FAILED=$((FAILED+1)); fi

# ── Fall D: der RECHNER startet neu (Agent UND Schritt sind weg) ─────────
# Das ist der harte Fall (User 2026-10-15): nicht nur der Agent stirbt, auch
# der abgekoppelte Beobachter ist mit dem Rechner verschwunden.  Der Agent
# liest beim Start seine Schritt-Ablage (doc/spec/103 §103.4a), findet den
# Prozess nicht mehr — und MELDET das (`release_step`, F103-12).
#
# Geprueft wird genau der Unterschied zur Frist: die Meldung muss binnen
# Sekunden kommen, nicht nach 30 s Lehen.
echo "[chaos] Fall D: Rechner-Neustart — Agent UND Schritt werden getoetet"
: > "$LOGS/e2echaos_agentD.log"
kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
COSMOS_AGENT_TOKEN="$TOKEN" ./agent --exec-url "$URL" --agent-id agent-e2e --labels e2e --bwrap-path "$BWRAP" \
    >> "$LOGS/e2echaos_agentD.log" 2>&1 &
APID=$!
COSMOS_STEP_SLEEP=12 COSMOS_E2E_URL="$URL" ./e2e_pipeline_run > "$LOGS/e2echaos_runD.log" 2>&1 &
CLIENT=$!
SPID=""
for _ in $(seq 1 60); do
    SPID=$(sed -n 's/.*gestartet (pid \([0-9]*\)).*/\1/p' "$LOGS/e2echaos_agentD.log" | tail -1)
    [ -n "$SPID" ] && break
    sleep 0.3
done
if [ -z "$SPID" ]; then
    echo "[chaos] FAIL Fall D: kein Schritt-Prozess gefunden"; FAILED=$((FAILED+1))
else
    echo "[chaos]   Schritt laeuft als pid $SPID — Prozessgruppe und Agent werden getoetet"
    kill -9 "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
    # Die eigene Prozessgruppe des Schritts (spec/23 §5.4) — so ist er WEG,
    # wie nach einem Stromausfall, und nicht nur abgekoppelt.
    kill -9 -- "-$SPID" 2>/dev/null || kill -9 "$SPID" 2>/dev/null
    sleep 1
    # UND die Status-Datei weg: beim Stromausfall kam der Beobachter nicht mehr
    # dazu, sie zu schreiben.  Bleibt sie liegen (wie beim bloss getoeteten
    # Prozess), ist der Rueckgabewert ja bekannt — DANN ist nichts verloren und
    # der Agent meldet 137, wie er soll.  Der Verlustfall ist genau der ohne.
    # NACH der Pause: der Beobachter schreibt sie noch, waehrend er stirbt, und
    # ein zu frueher Griff loescht eine Datei, die gleich wiederkommt.
    rm -f steps/*/*/status
    T0=$SECONDS
    COSMOS_AGENT_TOKEN="$TOKEN" ./agent --exec-url "$URL" --agent-id agent-e2e --labels e2e --bwrap-path "$BWRAP" \
        >> "$LOGS/e2echaos_agentD.log" 2>&1 &
    APID=$!
    echo "[chaos]   Agent wieder da ($APID)"
    GAVE=0
    for _ in $(seq 1 40); do          # 12 s Deckel — das Lehen laeuft erst nach 30 s ab
        grep -q "zurueckgegeben" "$LOGS/e2echaos_agentD.log" && { GAVE=1; break; }
        sleep 0.3
    done
    DT=$((SECONDS - T0))
    if [ "$GAVE" -eq 1 ]; then echo "[chaos] ok   Fall D: Verlust nach ${DT}s gemeldet (Lehen waere 30s)"
    else echo "[chaos] FAIL Fall D: keine Verlustmeldung binnen ${DT}s"; FAILED=$((FAILED+1)); fi
    grep -q "spurlos verschwunden" "$LOGS/e2echaos_agentD.log" \
        && echo "[chaos] ok   Fall D: der Agent hat den Verlust in seiner Ablage erkannt" \
        || { echo "[chaos] FAIL Fall D: Verlust nicht erkannt"; FAILED=$((FAILED+1)); }
    # Mit Geduld: das Protokoll des Servers wird blockweise geschrieben, nicht
    # zeilenweise — ein einmaliger Griff danach prueft die Pufferung, nicht das
    # Verhalten.
    SRV=0
    for _ in $(seq 1 30); do
        grep -q "gab .* zurueck" "$LOGS/e2echaos_cosmosd.log" && { SRV=1; break; }
        sleep 0.3
    done
    if [ "$SRV" -eq 1 ]; then echo "[chaos] ok   Fall D: der Server hat die Stufe neu zugeteilt"
    else echo "[chaos] FAIL Fall D: der Server nahm die Stufe nicht zurueck"; FAILED=$((FAILED+1)); fi
    wait "$CLIENT"; RD=$?
    if [ "$RD" -eq 0 ]; then echo "[chaos] ok   Fall D: der Lauf kommt trotzdem zu Ende"
    else echo "[chaos] FAIL Fall D (rc=$RD)"; tail -12 "$LOGS/e2echaos_runD.log"; FAILED=$((FAILED+1)); fi
fi

# Beide muessen den Lauf ueberlebt haben UND noch leben.
kill -0 "$DPID" 2>/dev/null || { echo "[chaos] FAIL cosmosd ist gestorben"; FAILED=$((FAILED+1)); }
kill -0 "$APID" 2>/dev/null || { echo "[chaos] FAIL Agent ist gestorben"; FAILED=$((FAILED+1)); }

echo "========================================================"
if [ "$FAILED" -eq 0 ]; then echo "[chaos] PASS"; else echo "[chaos] FAIL ($FAILED)"; fi
exit "$FAILED"
