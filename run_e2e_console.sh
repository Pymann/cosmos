#!/usr/bin/env bash
# Abnahme des ADMIN-Pfads der Skript-Konsole (doc/spec/108 C1, F108-15).
#
# Warum ein eigenes Skript und nicht ein Schritt in run_e2e.sh: die erste Freigabe ist
# eine BETRIEBSHANDLUNG (F108-3) und laeuft bei GESTOPPTEM Dienst — zwei Prozesse auf
# demselben KV sind nicht vorgesehen.  Der Ablauf braucht also einen Neustart in der
# Mitte, und das gehoert nicht in einen Lauf, der sonst durchlaeuft.
set -uo pipefail
cd "$(dirname "$0")"
PROJ="$PWD"
LOGS="$PWD/logs"; mkdir -p "$LOGS"
PORT="${PORT:-18823}"
URL="ws://127.0.0.1:$PORT"
WORK="$PWD/.e2e_console"; rm -rf "$WORK"; mkdir -p "$WORK/deploy/clearance"

# IMMER bauen, nicht nur mit --build.  Grund (gemessen 17.10.2026): `ConsoleExecResult`
# bekam ein Feld, cosmosd wurde neu gebaut, der e2e-Client nicht — und der RPC-Fingerprint
# wies die Antwort zurueck ("response is not the expected 'set_result' payload").  Das ist
# der Schutz, der funktioniert hat; die Stunde Suche davor war vermeidbar.  Wer ein
# geteiltes Modell aendert, muss ALLE Sprecher dieses RPC neu bauen — also tut es das
# Skript.  Mit --no-build laesst es sich ueberspringen.
if [ "${1:-}" != "--no-build" ]; then
    source ../../exvenv/bin/activate
    for cfg in exodus-cosmosd.json exodus-console-offer.json exodus-test-cadmin.json; do
        exodus build -c "$cfg" || { echo "BUILD FAILED $cfg"; exit 1; }
    done
fi
for bin in cosmosd e2e_console_admin libcosmos_console_offer.so; do
    [ -e "./$bin" ] || { echo "fehlt: ./$bin — mit --build starten"; exit 1; }
done
cp cosmosd e2e_console_admin libcosmos_console_offer.so "$WORK/"
cp deploy/clearance/* "$WORK/deploy/clearance/"

export AIONDB_PATH="$WORK/aiondb"
export COSMOS_CONSOLE_AIML="$PROJ/../aiml/out/aiml/aiml"
export COSMOS_CONSOLE_EXPORTS="$WORK/deploy/clearance/console_exports.txt"
export COSMOS_CONSOLE_PREAMBLE="$WORK/deploy/clearance/console_preamble.aiml"
export COSMOS_CONSOLE_LIB="$WORK/libcosmos_console_offer.so"
export COSMOS_CONSOLE_SNAPSHOT="$WORK/snapshot.txt"
export COSMOS_CONSOLE_WORK="$WORK/runs"

# Je Phase ein EIGENER Port: ein frisch geschlossener Socket bleibt kurz belegt, und
# darauf zu warten ist fehleranfaelliger als ihm auszuweichen.
start_server() {
    PORT=$((18823 + $1))
    URL="ws://127.0.0.1:$PORT"
    # `exec`: die Subshell wird ZU cosmosd, also ist `$!` wirklich seine PID.
    # Ohne das lieferte `$!` die PID der SUBSHELL — der Kill traf die Huelle, der
    # Server blieb verwaist und hielt den Port (drei Leichen, gemessen 17.10.2026).
    ( cd "$WORK" && exec env COSMOS_BIND="$URL" ./cosmosd > "$LOGS/e2e_console_srv$1.log" 2>&1 ) &
    echo $! > "$WORK/pid"
    for _ in $(seq 1 60); do
        grep -q "listening on" "$LOGS/e2e_console_srv$1.log" 2>/dev/null && return 0
        sleep 0.25
    done
    echo "[console-e2e] Server kam nicht hoch"; tail -5 "$LOGS/e2e_console_srv$1.log"; return 1
}
# Warten, bis der Port WIRKLICH frei ist: `kill` kehrt sofort zurueck, der Socket
# bleibt aber noch einen Moment belegt — der zweite Start scheiterte genau daran
# ("Port belegt? (laeuft schon ein cosmosd?)", gemessen 17.10.2026).
stop_server() {
    local pid; pid=$(cat "$WORK/pid" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    # Wer nach 10 s noch horcht, geht hart — ein Server, der den Port haelt, blockiert
    # den naechsten Lauf, und das sieht dann aus wie ein Fehler im Pruefling.
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    for _ in $(seq 1 60); do
        ss -ltn 2>/dev/null | grep -q ":$PORT " || break
        sleep 0.25
    done
}

# Der Server MUSS auch auf Fehlerpfaden sterben — sonst haelt er den Port, und der
# naechste Lauf scheitert an sich selbst (gemessen 17.10.2026: zwei Laeufe, einer
# hinterliess einen horchenden cosmosd).
trap stop_server EXIT

rc=0
start_server 1 || exit 1
echo "[console-e2e] Phase 1 — noch kein Admin"
( cd "$WORK" && COSMOS_E2E_URL="$URL" COSMOS_E2E_PHASE=1 ./e2e_console_admin ) || rc=1
stop_server

echo "[console-e2e] Betriebshandlung: Freigabe 1 vergeben (Dienst ist AUS)"
( cd "$WORK" && ./cosmosd --grant-email admin-e2e@example.com --grant-level 1 ) || rc=1

start_server 2 || exit 1
echo "[console-e2e] Phase 2 — jetzt Admin"
( cd "$WORK" && COSMOS_E2E_URL="$URL" COSMOS_E2E_PHASE=2 ./e2e_console_admin ) || rc=1
stop_server

[ $rc -eq 0 ] && echo "[console-e2e] PASS" || echo "[console-e2e] FAIL"
exit $rc
