#!/usr/bin/env bash
# Abnahme: der RPC-Weg der Einrichtung gegen einen laufenden cosmosd.
# Diese Kette war NIE geprueft — der Fehler (Absturz in pthread_mutex_lock)
# fiel erst dem Nutzer auf.
set -uo pipefail
cd "$(dirname "$0")"
PORT="${PORT:-8802}"
URL="ws://127.0.0.1:${PORT}"
WORK="$PWD/.e2e_prov"
LOGS="$PWD/logs"

if [ "${1:-}" != "--run-only" ]; then
    # shellcheck disable=SC1091
    source ../../exvenv/bin/activate
    for cfg in exodus-cosmosd.json exodus-agent.json exodus-test-e2eprov.json; do
        exodus build -c "$cfg" || { echo "BUILD FAILED: $cfg"; exit 1; }
    done
fi
for bin in cosmosd agent e2e_provision; do
    [ -x "./$bin" ] || { echo "missing ./$bin"; exit 1; }
done

mkdir -p "$LOGS"; rm -rf "$WORK"; mkdir -p "$WORK"
cp cosmosd agent e2e_provision "$WORK/"
DAEMON_PID=""
cleanup() { [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT
cd "$WORK"
export AIONDB_PATH="$WORK/aiondb"

# Knoten-Vorgaben wie im Betrieb, nur in ein Wegwerf-Verzeichnis (§94.5a).
mkdir -p "$WORK/prov"; : > "$WORK/prov/subuid"; : > "$WORK/prov/subgid"
export COSMOS_AGENT_BINARY="./agent"
export COSMOS_PROV_INSTALL_DIR="$WORK/prov/opt"
export COSMOS_PROV_STAGE_DIR="$WORK/prov/stage"
export COSMOS_PROV_WORK_DIR="$WORK/prov/agentwork"
export COSMOS_PROV_APPARMOR_DIR="$WORK/prov/apparmor.d"
export COSMOS_PROV_SYSTEMD_DIR="$WORK/prov/systemd"
export COSMOS_PROV_SUBUID_FILE="$WORK/prov/subuid"
export COSMOS_PROV_SUBGID_FILE="$WORK/prov/subgid"
export COSMOS_PROV_SERVICE_USER="$(id -un)"
export COSMOS_PROV_SUDO="-"
export COSMOS_PROV_VERIFY_PREFIX="-"
export COSMOS_PROV_APPARMOR_CMD="true"
export COSMOS_PROV_PKG_CMD="true"
export COSMOS_PROV_SERVICE_CMD="true"
export COSMOS_PROV_CHECK_CMD="true"
export COSMOS_PROV_STOP_CMD="-"
export COSMOS_PROV_RELOAD_CMD="true"   # kein `systemctl daemon-reload` auf dem Entwicklerrechner
export COSMOS_PROV_EXEC_URL="$URL"
export COSMOS_AGENT_RUNTIME="$PWD/runtime.tar.gz"
tar -czf "$PWD/runtime.tar.gz" -T /dev/null 2>/dev/null

COSMOS_BIND="$URL" ./cosmosd > "$LOGS/e2eprov_cosmosd.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do
    grep -q "listening on" "$LOGS/e2eprov_cosmosd.log" 2>/dev/null && break
    sleep 0.2
done

COSMOS_E2E_URL="$URL" ./e2e_provision 2>&1 | tee "$LOGS/e2eprov_client.log"
RC=${PIPESTATUS[0]}
# Der Server MUSS den Lauf ueberleben — genau das tat er nicht.
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "[e2eprov] FAIL — cosmosd ist waehrend der Einrichtung GESTORBEN"
    tail -20 "$LOGS/e2eprov_cosmosd.log"
    RC=1
fi
echo "========================================================"
if [ "$RC" -eq 0 ]; then echo "[e2eprov] PASS"; else echo "[e2eprov] FAIL (rc=$RC)"; fi
exit "$RC"
