#!/usr/bin/env bash
# Probe: the step cache end to end (doc/spec/96 §96.7 A96-1, A96-2, A96-3).
#
# The same pipeline runs twice on ONE agent in container mode (--in-container
# 1: layers per stage on overlayfs).  Expected:
#   run 1  both pure stages RUN and keep their layer
#   run 2  both pure stages come out of the cache, nothing of theirs runs;
#          the opaque check runs every time and sees the restored file
#          system, including the file stage one deleted (whiteout, A96-3)
#   run 3  the resolved stage's probe answers differently ("a commit on the
#          branch"): that stage runs again, the pure ones still do not (A96-2)
#
# Needs root (unshare -m, overlay over "/"), like an agent in a container.
#   probe/step_cache.sh [--run-only]
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8811}"
URL="ws://127.0.0.1:${PORT}"
WORK="$PWD/.e2e_cache"
LOGS="$PWD/logs/probe_step_cache"

if [ "${1:-}" != "--run-only" ]; then
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    for cfg in exodus-cosmosd.json exodus-agent.json exodus-test-enroll.json exodus-test-e2epipe.json; do
        aiml build -c "$cfg" > /dev/null || { echo "BUILD FAILED: $cfg"; exit 1; }
    done
fi
[ "$(id -u)" = 0 ] || { echo "[cache] SKIP — needs root (overlay over /)"; exit 0; }

rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
cp cosmosd agent e2e_enroll e2e_pipeline_run "$WORK/"
# The file stage one deletes must exist in the base for the whiteout to mean
# anything.  It lives on the host: in container mode the host IS the image.
touch /etc/cache-weg
echo commit-aaa > /tmp/cosmos-cache-rev

DAEMON_PID=""; AGENT_PID=""
cleanup() {
    [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    wait 2>/dev/null
    rm -f /etc/cache-weg /tmp/cosmos-cache-rev
}
trap cleanup EXIT
cd "$WORK"
export AIONDB_PATH="$WORK/aiondb"

COSMOS_BIND="$URL" ./cosmosd > "$LOGS/cosmosd.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do grep -q "listening on" "$LOGS/cosmosd.log" 2>/dev/null && break; sleep 0.2; done
TOKEN=$(COSMOS_E2E_URL="$URL" ./e2e_enroll 2>"$LOGS/enroll.log")
[ -n "$TOKEN" ] || { echo "[cache] FAIL — no agent token"; exit 1; }
# The work root on a file system of its own, as /work is in a real container:
# overlayfs refuses a lower stack ("/") that contains its own upper dirs
# (ELOOP, "Too many levels of symbolic links").  Own mount namespace, so the
# tmpfs goes away with the agent.
mkdir -p "$WORK/steps"
COSMOS_AGENT_TOKEN="$TOKEN" unshare -m sh -c 'mount -t tmpfs -o mode=0755 tmpfs "$1" && shift && exec "$@"' sh \
    "$WORK/steps" ./agent --exec-url "$URL" --agent-id agent-e2e --labels e2e \
    --bwrap-path /bin/true --work-root "$WORK/steps" --in-container 1 > "$LOGS/agent.log" 2>&1 &
AGENT_PID=$!

RC=0
for round in 1 2 3; do
    [ "$round" = 3 ] && echo commit-bbb > /tmp/cosmos-cache-rev
    COSMOS_CACHE_PROBE=1 COSMOS_E2E_URL="$URL" ./e2e_pipeline_run > "$LOGS/run$round.log" 2>&1 \
        && echo "[cache] ok   run $round passed" \
        || { echo "[cache] FAIL — run $round:"; tail -5 "$LOGS/run$round.log"; RC=1; }
done
# The stages say what they did on stdout; the server keeps it per stage.
ran_one=$(grep -l "stufe-eins-lief" run_logs/*.out 2>/dev/null | wc -l)
ran_two=$(grep -l "stufe-zwei-lief" run_logs/*.out 2>/dev/null | wc -l)
reused=$(grep -l "Schritt-Cache (Schluessel" run_logs/*.out 2>/dev/null | wc -l)
checked=$(grep -l "stufen-stand-ok" run_logs/*.out 2>/dev/null | wc -l)
fetched=$(grep -l "stufe-holen-lief" run_logs/*.out 2>/dev/null | wc -l)
kept=$(grep -c "Schicht unter .* aufgehoben" "$LOGS/agent.log")
[ "$ran_one" = 1 ] && [ "$ran_two" = 1 ] \
    && echo "[cache] ok   the pure stages ran once, not twice (A96-1)" \
    || { echo "[cache] FAIL — stage one ran $ran_one x, stage two $ran_two x (want 1 and 1)"; RC=1; }
# reused: run 2 takes eins, zwei, holen; run 3 eins, zwei = 5
[ "$reused" = 5 ] && echo "[cache] ok   runs 2 and 3 took their layers from the cache (5)" \
    || { echo "[cache] FAIL — $reused stage(s) reused (want 5)"; RC=1; }
# kept: run 1 eins, zwei, holen; run 3 holen under its new key = 4
[ "$kept" = 4 ] && echo "[cache] ok   four layers kept (run 1: three, run 3: the moved one)" \
    || { echo "[cache] FAIL — $kept layer(s) kept (want 4)"; RC=1; }
[ "$fetched" = 2 ] && echo "[cache] ok   the resolved stage ran again only after its probe moved (A96-2)" \
    || { echo "[cache] FAIL — the resolved stage ran $fetched x (want 2: run 1 and run 3)"; RC=1; }
[ "$checked" = 3 ] && echo "[cache] ok   the opaque check ran every time and saw the same file system, whiteout included (A96-3)" \
    || { echo "[cache] FAIL — the check passed $checked x (want 3)"; RC=1; }
echo "========================================================"
[ "$RC" = 0 ] && echo "[cache] PASS" || echo "[cache] FAIL — logs in $LOGS"
exit "$RC"
