#!/usr/bin/env bash
# Abnahme: ein Pipeline-Lauf laeuft WIRKLICH auf einem Agenten (doc/spec/103).
# Eigener Prüfstand, weil der Agent hier ETIKETTEN traegt und endlos laeuft —
# die AP1-Abnahme (run_e2e.sh) fährt ihn mit --stop-after.
#   ./run_e2e_pipeline.sh [--run-only]
set -uo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8801}"
URL="ws://127.0.0.1:${PORT}"
WORK="$PWD/.e2e_pipe"
LOGS="$PWD/logs"

if [ "${1:-}" != "--run-only" ]; then
    # shellcheck disable=SC1091
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    for cfg in exodus-cosmosd.json exodus-agent.json exodus-test-enroll.json exodus-test-e2epipe.json; do
        echo "=== building $cfg ==="
        aiml build -c "$cfg" || { echo "BUILD FAILED: $cfg"; exit 1; }
    done
fi
for bin in cosmosd agent e2e_enroll e2e_pipeline_run; do
    [ -x "./$bin" ] || { echo "missing ./$bin — ohne --run-only starten"; exit 1; }
done

mkdir -p "$LOGS"; rm -rf "$WORK"; mkdir -p "$WORK"
cp cosmosd agent e2e_enroll e2e_pipeline_run "$WORK/"

DAEMON_PID=""; AGENT_PID=""
cleanup() {
    [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

cd "$WORK"
export AIONDB_PATH="$WORK/aiondb"

# doc/spec/115: three declared secrets for the secret probe below.  The values
# are made up here and checked against the server's log afterwards.
TOKVAL="tok-e2e-$(date +%s%N | tail -c 9)-value"
PWVAL="pw-e2e-hunter2-$$"
mkdir -p casc/sec
printf '%s\n' "$PWVAL" > casc/sec/pw
printf 'signing-file-content\n' > casc/sec/sign
cat > casc/casc.yaml <<'CASC'
- config:
    secrets:
      - secret: { name: tok, env: COSMOS_E2E_TOK }
      - secret: { name: deploy, kind: user_password, user: e2e-deployer, file: sec/pw }
      - secret: { name: sign, kind: file, file: sec/sign }
CASC

COSMOS_E2E_TOK="$TOKVAL" COSMOS_CASC="$WORK/casc/casc.yaml" COSMOS_BIND="$URL" ./cosmosd > "$LOGS/e2epipe_cosmosd.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do
    grep -q "listening on" "$LOGS/e2epipe_cosmosd.log" 2>/dev/null && break
    sleep 0.2
done

AGENT_TOKEN=$(COSMOS_E2E_URL="$URL" ./e2e_enroll 2>"$LOGS/e2epipe_enroll.log")
if [ -z "$AGENT_TOKEN" ]; then
    echo "[e2epipe] FAIL — Token-Erzeugung fehlgeschlagen"; tail -5 "$LOGS/e2epipe_enroll.log"; exit 1
fi
echo "[e2epipe] Token erzeugt (Geheimnis nicht geloggt)"

# Etikett `e2e`: der Lauf hat eine Stufe mit `label: e2e`, die NUR dieser Agent
# nehmen darf — damit prueft die Abnahme die Zuteilung mit, nicht nur das Laufen.
# Der Sandkasten (doc/spec/91): die mitgelieferte Kopie unter /opt/cosmos gibt es
# nur auf einem eingerichteten Knoten, hier tut es das bwrap des Rechners.
BWRAP="${COSMOS_BWRAP:-$(command -v bwrap || echo /opt/cosmos/bwrap)}"
[ -x "$BWRAP" ] || { echo "[e2epipe] FAIL — kein bwrap (apt install bubblewrap, oder COSMOS_BWRAP)"; exit 1; }
COSMOS_AGENT_TOKEN="$AGENT_TOKEN" \
    ./agent --exec-url "$URL" --agent-id agent-e2e --labels e2e --bwrap-path "$BWRAP" > "$LOGS/e2epipe_agent.log" 2>&1 &
AGENT_PID=$!
echo "[e2epipe] agent pid $AGENT_PID (labels=e2e)"

COSMOS_E2E_URL="$URL" ./e2e_pipeline_run 2>&1 | tee "$LOGS/e2epipe_client.log"
RC=${PIPESTATUS[0]}

# ── F103-14: das Token des Agenten darf im Schritt NICHT auftauchen ──────
# Die Stufe `umgebung` gibt `env` aus; ihre Ausgabe liegt im Schrittverzeichnis.
# Geprueft wird der WERT, nicht der Name: ein Schritt, der ihn lesen kann, kann
# sich als der Agent ausgeben.
ENVOUT=$(grep -rl "^PATH=" steps/*/*/out 2>/dev/null | head -1)
if [ -z "$ENVOUT" ]; then
    echo "[e2epipe] FAIL — keine Umgebungs-Ausgabe gefunden (lief die Stufe?)"; RC=1
else
    if grep -q "$AGENT_TOKEN" "$ENVOUT"; then
        echo "[e2epipe] FAIL — das Agenten-Token steht in der Schritt-Umgebung!"; RC=1
    else
        echo "[e2epipe] ok   kein Agenten-Token in der Schritt-Umgebung (F103-14)"
    fi
    if grep -q "COSMOS_" "$ENVOUT"; then
        echo "[e2epipe] FAIL — COSMOS_* in der Schritt-Umgebung: $(grep -o 'COSMOS_[A-Z_]*' "$ENVOUT" | sort -u | tr '\n' ' ')"; RC=1
    else
        echo "[e2epipe] ok   keine COSMOS_*-Variable im Schritt"
    fi
    grep -q "^PATH=/usr/bin:/bin" "$ENVOUT" \
        && echo "[e2epipe] ok   der Schritt bekommt den gebauten PATH" \
        || { echo "[e2epipe] FAIL — PATH ist nicht der gebaute"; RC=1; }
fi

# ── F103-19: landet die AUSGABE des Schritts auf dem Server? ─────────────
# Bis 2026-10-15 lag sie nur auf dem Agenten — ein Fehlschlag war eine Zahl
# ohne Text.  Geprueft wird die Datei des SERVERS (run_logs/<stufe>.out), nicht
# das Schrittverzeichnis des Agenten.
SRVLOG=$(grep -rl "stufe-eins" run_logs/*.out 2>/dev/null | head -1)
if [ -z "$SRVLOG" ]; then
    echo "[e2epipe] FAIL — die Ausgabe des Schritts steht nicht im Server-Protokoll"
    ls -la run_logs/ 2>/dev/null | head -5
    RC=1
else
    echo "[e2epipe] ok   stdout des Schritts liegt auf dem Server ($(basename "$SRVLOG"))"
    # Der Bezeichner ist die STUFEN-Kennung, nicht die Lauf-Kennung: zwei Lanes
    # duerfen sich nicht in eine Datei schreiben.
    case "$(basename "$SRVLOG" .out)" in
        *-0-0) echo "[e2epipe] ok   je Stufe ein eigenes Protokoll" ;;
        *) echo "[e2epipe] FAIL — unerwarteter Protokoll-Bezeichner: $(basename "$SRVLOG")"; RC=1 ;;
    esac
    # Und die Ausgabe der SPAETEREN Stufen ebenfalls (nicht nur die erste).
    grep -rq "stufe-drei" run_logs/*.out 2>/dev/null \
        && echo "[e2epipe] ok   auch die letzte Stufe hat ihr Protokoll" \
        || { echo "[e2epipe] FAIL — die letzte Stufe hinterliess kein Protokoll"; RC=1; }
fi

# ── F103-17: die Zeitgrenze, am laufenden System ─────────────────────────
echo "[e2epipe] Zeitgrenzen-Probe (2 s Grenze, 30 s Schlaf)"
COSMOS_TIMEOUT_PROBE=1 COSMOS_E2E_URL="$URL" ./e2e_pipeline_run 2>&1 | tee "$LOGS/e2epipe_timeout.log"
TRC=${PIPESTATUS[0]}
if [ "$TRC" -eq 0 ]; then echo "[e2epipe] ok   der haengende Schritt wurde abgebrochen"
else echo "[e2epipe] FAIL — die Zeitgrenze griff nicht"; RC=1; fi
grep -q "124" "$LOGS/e2epipe_agent.log" \
    && echo "[e2epipe] ok   der Agent meldete 124 (Zeitgrenze)" \
    || echo "[e2epipe] Hinweis: kein 124 im Agenten-Protokoll"

# ── doc/spec/115: secrets for steps (A115-1..6) ─────────────────────────
echo "[e2epipe] Secret-Probe (token, user_password, file; dann ein fehlendes)"
COSMOS_SECRET_PROBE=1 COSMOS_E2E_URL="$URL" ./e2e_pipeline_run > "$LOGS/e2epipe_secrets.log" 2>&1 &
SPID=$!
# A115-6: while the stage sleeps, no process shows a value in its arguments.
PS_HITS=0
for _ in $(seq 1 30); do
    ps -eo args > ps.dump 2>/dev/null
    grep -qF -- "$TOKVAL" ps.dump && PS_HITS=$((PS_HITS+1))
    grep -qF -- "$PWVAL" ps.dump && PS_HITS=$((PS_HITS+1))
    sleep 0.3
done
wait "$SPID"; SRC=$?
cat "$LOGS/e2epipe_secrets.log"
[ "$SRC" -eq 0 ] || { echo "[e2epipe] FAIL — Secret-Probe"; RC=1; }
[ "$PS_HITS" -eq 0 ] && echo "[e2epipe] ok   kein Wert in einer Befehlszeile (A115-6)" \
    || { echo "[e2epipe] FAIL — ein Wert stand $PS_HITS mal in ps"; RC=1; }
SECLOG=$(grep -l "secret-stage-done" run_logs/*.out 2>/dev/null | head -1)
if [ -z "$SECLOG" ]; then
    echo "[e2epipe] FAIL — kein Server-Protokoll der Secret-Stufe"; RC=1
else
    TOKB64=$(printf %s "$TOKVAL" | base64)
    BASIC=$(printf %s "e2e-deployer:$PWVAL" | base64)
    for val in "$TOKVAL" "$PWVAL" "$TOKB64" "$BASIC"; do
        if grep -qF -- "$val" "$SECLOG"; then echo "[e2epipe] FAIL — ein Wert steht im Server-Protokoll"; RC=1; fi
    done
    grep -q "^tok=\*\*\*\*$" "$SECLOG" && echo "[e2epipe] ok   token maskiert (A115-1)" || { echo "[e2epipe] FAIL — tok= nicht maskiert"; RC=1; }
    grep -q "^user=e2e-deployer pw=\*\*\*\*$" "$SECLOG" && echo "[e2epipe] ok   _USER sichtbar, _PASSWORD maskiert (A115-3)" || { echo "[e2epipe] FAIL — user/pw"; RC=1; }
    grep -q "a\*\*\*\*$" "$SECLOG" && echo "[e2epipe] ok   Wert ueber der 64-KiB-Grenze maskiert (A115-2)" || { echo "[e2epipe] FAIL — Wert an der Chunk-Grenze"; RC=1; }
    # The file's content is a line of 16 bytes or more, so it is masked too (F115-18).
    grep -q "^sign=\*\*\*\* mode=400$" "$SECLOG" && echo "[e2epipe] ok   file: Pfad auf 0400-Datei, Inhalt maskiert (A115-4)" || { echo "[e2epipe] FAIL — file-Secret"; RC=1; }
    SDIR=$(sed -n 's/^secret-dir=//p' "$SECLOG" | head -1)
    case "$SDIR" in
        *.secrets) [ -e "$SDIR" ] && { echo "[e2epipe] FAIL — $SDIR liegt nach dem Lauf noch da"; RC=1; } \
                   || echo "[e2epipe] ok   Secret-Verzeichnis neben dem Schritt, danach weg (F115-11)" ;;
        *) echo "[e2epipe] FAIL — Secret-Verzeichnis unerwartet: '$SDIR'"; RC=1 ;;
    esac
fi
grep -rqF -- "$TOKVAL" "$LOGS/e2epipe_cosmosd.log" "$LOGS/e2epipe_agent.log" \
    && { echo "[e2epipe] FAIL — ein Wert steht im Dienst-Protokoll"; RC=1; } \
    || echo "[e2epipe] ok   kein Wert in den Protokollen von Server und Agent"

echo "========================================================"
if [ "$RC" -eq 0 ]; then echo "[e2epipe] PASS"; else echo "[e2epipe] FAIL (rc=$RC) — logs in logs/e2epipe_*.log"; fi
exit "$RC"
