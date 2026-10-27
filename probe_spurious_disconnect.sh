#!/usr/bin/env bash
# PROBE: Meldet cosmosd einen peer_disconnected für einen LEBENDEN Peer, nur weil
# sich ein ANDERER Client getrennt hat?
#
# Beobachtet in den AP1-Messungen: ~1 s nach dem Disconnect eines Clients kam ein
# peer_disconnected mit der peer_id des Agenten; derselbe Agent lieferte danach
# weiter RPCs.  Diese Probe nimmt jede Ausgabe-Last heraus: der Agent registriert
# sich und bleibt IDLE (kein Kommando, kein Chunk).  Dann trennen sich mehrere
# kurzlebige Clients.
#
# REPRODUZIERT = cosmosd meldet peer_disconnected für die peer_id des Agenten,
#                obwohl der Agent läuft.
#
# Warum ein Shell-Skript und keine .aiml-Probe: mirror.listen und
# mirror.connect_timeout im SELBEN Prozess blockieren sich — connect pumpt nur
# die eigene Session, der Listener wird währenddessen nicht bedient, der
# Handshake kommt nie zustande.  Eine Mirror-Probe braucht zwei Prozesse.
#
# Ergebnis 2026-10-09: NICHT reproduziert (4/4 fremde Disconnects korrekt
# zugeordnet, der idle Agent blieb verbunden) → die Hypothese „fremder
# Client-Disconnect trennt einen anderen Peer" ist widerlegt; auslösend ist
# der unbegrenzte Sende-Schwall (doc/spec/90 §AP1.7-D7).
set -uo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8833}"
URL="ws://127.0.0.1:${PORT}"
WORK="$PWD/.probe_run"
LOGS="$PWD/logs"

for bin in cosmosd agent e2e_enroll; do
    [ -x "./$bin" ] || { echo "missing ./$bin"; exit 1; }
done

mkdir -p "$LOGS"
rm -rf "$WORK"
mkdir -p "$WORK"
cp cosmosd agent e2e_enroll "$WORK/"

DAEMON_PID=""
AGENT_PID=""
cleanup() {
    [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

cd "$WORK"
export AIONDB_PATH="$WORK/aiondb"
LOG="$LOGS/probe_cosmosd.log"

COSMOS_BIND="$URL" ./cosmosd > "$LOG" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do grep -q "listening on" "$LOG" 2>/dev/null && break; sleep 0.2; done

TOKEN=$(COSMOS_E2E_URL="$URL" ./e2e_enroll 2>/dev/null)
[ -n "$TOKEN" ] || { echo "PROBE FAIL: kein Token"; exit 1; }

COSMOS_AGENT_TOKEN="$TOKEN" ./agent --exec-url "$URL" --agent-id agent-idle > "$LOGS/probe_agent.log" 2>&1 &
AGENT_PID=$!
sleep 2

AGENT_PEER=$(grep -o "agent-idle connected peer=[0-9]*" "$LOG" | tail -1 | grep -o "[0-9]*$")
[ -n "$AGENT_PEER" ] || { echo "PROBE FAIL: Agent hat sich nicht registriert"; tail -5 "$LOGS/probe_agent.log"; exit 1; }
echo "[probe] Agent idle als peer=$AGENT_PEER (keine Ausgabe-Last)"

MARK=$(grep -c "" "$LOG")

# Mehrere kurzlebige Clients: jeder verbindet sich, meldet sich an, trennt sich.
for i in 1 2 3 4; do
    COSMOS_E2E_URL="$URL" ./e2e_enroll >/dev/null 2>&1
    sleep 1
done
sleep 3

echo "[probe] Server-Ereignisse nach den Client-Disconnects:"
tail -n +"$((MARK + 1))" "$LOG" | grep -E "peer_disconnected|agent .* disconnected|lost during" || echo "  (keine)"

if tail -n +"$((MARK + 1))" "$LOG" | grep -q "peer_disconnected peer=${AGENT_PEER}\b"; then
    echo "[probe] REPRODUZIERT — Disconnect für den lebenden Agenten (peer=$AGENT_PEER)"
    if kill -0 "$AGENT_PID" 2>/dev/null; then
        echo "[probe]   ... und der Agent-Prozess läuft weiter (Verbindung also nicht wirklich tot)"
    fi
    grep -c "cosmosd connection lost" "$LOGS/probe_agent.log" | sed 's/^/[probe]   Agent-Sicht "Verbindung verloren": /'
    exit 1
fi
echo "[probe] NICHT reproduziert — kein Disconnect für den Agenten"
exit 0
