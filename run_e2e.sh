#!/usr/bin/env bash
# AP1-Abnahme end-to-end (doc/spec/90 §AP1.5 + §AP1.9).
#   ./run_e2e.sh              # bauen + fahren
#   ./run_e2e.sh --run-only   # vorhandene Binaries fahren
#
# Fluss wie in echt: Nutzer meldet sich an und erzeugt ein Agent-Token (§AP1.9),
# der Agent startet damit.  Danach die Negativfälle: falsches Token und
# widerrufenes Token müssen abgelehnt werden.
# Logs in logs/ (persistent).  Das Token selbst wird NICHT in Logs geschrieben.
set -uo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8799}"
URL="ws://127.0.0.1:${PORT}"
WORK="$PWD/.e2e_run"
LOGS="$PWD/logs"

if [ "${1:-}" != "--run-only" ]; then
    # shellcheck disable=SC1091
    # In einem Container liegt exodus woanders und steht schon auf PATH.
    [ -f ../../exvenv/bin/activate ] && source ../../exvenv/bin/activate
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    for cfg in exodus-cosmosd.json exodus-agent.json exodus-test-e2e.json exodus-test-enroll.json \
           exodus-test-surface.json; do
        echo "=== building $cfg ==="
        exodus build -c "$cfg" || { echo "BUILD FAILED: $cfg"; exit 1; }
    done
fi

for bin in cosmosd agent e2e_agent_exec e2e_enroll e2e_rpc_surface; do
    [ -x "./$bin" ] || { echo "missing ./$bin — run without --run-only"; exit 1; }
done

mkdir -p "$LOGS"
rm -rf "$WORK"
mkdir -p "$WORK"
cp cosmosd agent e2e_agent_exec e2e_enroll e2e_rpc_surface "$WORK/"

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

# Knoten-Vorgaben fuer die Agenten-Einrichtung (doc/spec/94 §94.5a).  Alles
# zeigt in ein Wegwerf-Verzeichnis, sudo ist leer, und die drei Systembefehle
# sind harmlos — es wird NICHTS am Rechner geaendert.  Das sind dieselben
# Variablen wie im Betrieb, keine Testschalter.
mkdir -p "$WORK/prov"
: > "$WORK/prov/subuid"
: > "$WORK/prov/subgid"
export COSMOS_AGENT_BINARY="./agent"
export COSMOS_PROV_INSTALL_DIR="$WORK/prov/opt"
export COSMOS_PROV_STAGE_DIR="$WORK/prov/stage"
export COSMOS_PROV_APPARMOR_DIR="$WORK/prov/apparmor.d"
export COSMOS_PROV_SYSTEMD_DIR="$WORK/prov/systemd"
export COSMOS_PROV_SUBUID_FILE="$WORK/prov/subuid"
export COSMOS_PROV_SUBGID_FILE="$WORK/prov/subgid"
export COSMOS_PROV_SERVICE_USER="$(id -un)"
export COSMOS_PROV_SUDO="-"            # "-" = leer (Konvention, s. §94.5a)
export COSMOS_PROV_VERIFY_PREFIX="-"
export COSMOS_PROV_APPARMOR_CMD="true"
export COSMOS_PROV_PKG_CMD="true"
export COSMOS_PROV_SERVICE_CMD="true"
export COSMOS_PROV_CHECK_CMD="true"
export COSMOS_PROV_STOP_CMD="-"
export COSMOS_PROV_RELOAD_CMD="true"   # kein `systemctl daemon-reload` auf dem Entwicklerrechner
export COSMOS_PROV_EXEC_URL="$URL"

COSMOS_SEED_DEMO=1 COSMOS_BIND="$URL" ./cosmosd > "$LOGS/e2e_cosmosd.log" 2>&1 &
DAEMON_PID=$!
echo "[e2e] cosmosd pid $DAEMON_PID on $URL"
for _ in $(seq 1 50); do
    grep -q "listening on" "$LOGS/e2e_cosmosd.log" 2>/dev/null && break
    sleep 0.2
done

FAILED=0

# ── RPC-Oberfläche: die Handler ohne Agenten-Beteiligung ────────────────────
# Auth-Profil, Logout, validate_token, Cluster-Leser.  Seit der Umstellung auf
# Gruppen-Instanzen (spec/58) laufen deren Dienst-Zugriffe über sees-Kanten;
# eine falsche Kante faellt erst beim Dispatch auf.  Laeuft im selben cosmosd,
# damit nicht pro Handler ein Server gebaut und gestartet werden muss.
COSMOS_E2E_URL="$URL" ./e2e_rpc_surface 2>&1 | tee "$LOGS/e2e_surface.log"
SURFACE_RC=${PIPESTATUS[0]}
[ "$SURFACE_RC" -eq 0 ] || FAILED=$((FAILED + 1))

# ── §AP1.9: Token im UI-Fluss erzeugen (hier über denselben RPC) ─────────────
AGENT_TOKEN=$(COSMOS_E2E_URL="$URL" ./e2e_enroll 2>"$LOGS/e2e_enroll.log")
if [ -z "$AGENT_TOKEN" ]; then
    echo "[e2e] FAIL — Token-Erzeugung fehlgeschlagen"
    tail -10 "$LOGS/e2e_enroll.log"
    exit 1
fi
TOKEN_ID="${AGENT_TOKEN%%.*}"
echo "[e2e] Agent-Token erzeugt (id $TOKEN_ID, Geheimnis nicht geloggt)"

# ── Kriterium 12: falsches Token wird abgelehnt ──────────────────────────────
COSMOS_AGENT_TOKEN="${TOKEN_ID}.0000000000000000000000000000000000000000000000000000000000000000" \
    ./agent --exec-url "$URL" --agent-id agent-bogus --stop-after 1 > "$LOGS/e2e_agent_bogus.log" 2>&1 &
BOGUS_PID=$!
sleep 2
kill "$BOGUS_PID" 2>/dev/null
if grep -q "registration refused" "$LOGS/e2e_agent_bogus.log"; then
    echo "[e2e] ok   — falsches Token abgelehnt (Kriterium 12)"
else
    echo "[e2e] FAIL — falsches Token wurde NICHT abgelehnt (Kriterium 12)"
    FAILED=$((FAILED + 1))
fi

# ── Hauptlauf mit gültigem Token ─────────────────────────────────────────────
COSMOS_AGENT_TOKEN="$AGENT_TOKEN" \
    ./agent --exec-url "$URL" --agent-id agent-e2e --stop-after 2 > "$LOGS/e2e_agent.log" 2>&1 &
AGENT_PID=$!
echo "[e2e] agent pid $AGENT_PID (Kriterium 11: Token aus dem UI)"

COSMOS_E2E_URL="$URL" ./e2e_agent_exec 2>&1 | tee "$LOGS/e2e_client.log"

# doc/spec/109 R4: JETZT laeuft ein Agent — also jetzt pruefen, ob er seine Last meldet.
# Der Hauptlauf oben kann das nicht: da gibt es noch keinen Agenten.
COSMOS_E2E_URL="$URL" COSMOS_E2E_AGENTLOAD=1 ./e2e_rpc_surface 2>&1 | tee "$LOGS/e2e_agentload.log"
AGENTLOAD_RC=${PIPESTATUS[0]}
RESULT=${PIPESTATUS[0]}
[ "$RESULT" -eq 0 ] || FAILED=$((FAILED + 1))

# Agent beendet sich nach --stop-after 2 selbst
wait "$AGENT_PID" 2>/dev/null
AGENT_PID=""

# ── Kriterium 13: widerrufenes Token wird abgelehnt ─────────────────────────
REVOKED=$(COSMOS_E2E_URL="$URL" COSMOS_REVOKE_ID="$TOKEN_ID" ./e2e_enroll 2>"$LOGS/e2e_revoke.log")
if [ "$REVOKED" != "revoked" ]; then
    echo "[e2e] FAIL — Widerruf fehlgeschlagen"
    FAILED=$((FAILED + 1))
else
    COSMOS_AGENT_TOKEN="$AGENT_TOKEN" \
        ./agent --exec-url "$URL" --agent-id agent-after-revoke --stop-after 1 > "$LOGS/e2e_agent_revoked.log" 2>&1 &
    REV_PID=$!
    sleep 2
    kill "$REV_PID" 2>/dev/null
    if grep -q "registration refused" "$LOGS/e2e_agent_revoked.log"; then
        echo "[e2e] ok   — widerrufenes Token abgelehnt (Kriterium 13)"
    else
        echo "[e2e] FAIL — widerrufenes Token wurde NICHT abgelehnt (Kriterium 13)"
        FAILED=$((FAILED + 1))
    fi
fi

echo "========================================================"
if [ "$FAILED" -eq 0 ]; then
    echo "[e2e] PASS — logs in logs/e2e_*.log"
    exit 0
fi
echo "[e2e] FAIL ($FAILED Prüfung(en)) — logs in logs/e2e_*.log"
echo "--- cosmosd (tail) ---"; tail -20 "$LOGS/e2e_cosmosd.log"
echo "--- agent (tail) ---";   tail -20 "$LOGS/e2e_agent.log"
exit 1
