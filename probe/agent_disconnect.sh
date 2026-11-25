#!/usr/bin/env bash
# Probe: durable job across agent disconnect (Jenkins durable-task semantics, aiml sys.exe detach).
#  1. controller + agent start, agent launches the job (sys.exe detach + status_file)
#  2. agent is killed (SIGKILL)       -> job keeps running, controller persists agent_lost
#  3. controller is killed (SIGKILL)  -> restart restores the serialized job state from KV
#  4. agent restarts                  -> reattaches, streams the rest of the log, job finishes
# Checks: same job pid throughout, log complete + identical on both sides, exit code delivered.
# Usage: probe/agent_disconnect.sh [--build]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

if [ "${1:-}" = "--build" ]; then
    # shellcheck disable=SC1091
    aiml build -c exodus-controller.json || exit 2
    aiml build -c exodus-agent.json || exit 2
fi

PORT=${PORT:-19870}
JOB=job-1
STEPS=40
CMD="i=1; while [ \$i -le $STEPS ]; do echo step \$i; i=\$((i+1)); sleep 0.2; done; exit 3"
RUN=$ROOT/out/probe/agent_disconnect
rm -rf "$RUN"; mkdir -p "$RUN/controller" "$RUN/agent"
CLOG=$RUN/controller.log
ALOG=$RUN/agent.log
JOBDIR=$RUN/agent/ws/$JOB
FAILS=0
CTL_PID=; AGENT_PID=; JOB_PID=
cleanup() { kill -9 $CTL_PID $AGENT_PID $JOB_PID 2>/dev/null; }
trap cleanup EXIT

pass() { echo "$(date +%T.%3N) PASS $*"; }
fail() { echo "$(date +%T.%3N) FAIL $*"; FAILS=$((FAILS+1)); }
wait_for() {   # wait_for <seconds> <cmd...>
    local limit; limit=$(echo "$1 * 10 / 1" | bc); shift
    for ((n = 0; n < limit; n++)); do "$@" && return 0; sleep 0.1; done
    return 1
}
log_lines() { [ -f "$JOBDIR/job.log" ] && wc -l < "$JOBDIR/job.log" || echo 0; }
start_controller() {
    (cd "$RUN/controller" && exec "$ROOT/controller" --port "$PORT" --job-id "$JOB" --command "$CMD" --exit-when-done >>"$CLOG" 2>&1) &
    CTL_PID=$!
}
start_agent() {
    (cd "$RUN/agent" && exec "$ROOT/agent" --port "$PORT" --agent-id agent-1 >>"$ALOG" 2>&1) &
    AGENT_PID=$!
}

start_controller
sleep 0.3
start_agent
wait_for 10 grep -q "launched $JOB pid=" "$ALOG" || { fail "job never launched"; cat "$CLOG" "$ALOG"; exit 1; }
JOB_PID=$(grep -o "launched $JOB pid=[0-9]*" "$ALOG" | head -1 | cut -d= -f2)
wait_for 10 bash -c "[ \$(wc -l < '$JOBDIR/job.log') -ge 5 ]"
echo "$(date +%T.%3N) job pid=$JOB_PID running, log lines=$(log_lines)"

INHERITED=$(ls -l /proc/"$JOB_PID"/fd 2>/dev/null | grep -c 'socket:\|\.kvwal')
if [ "$INHERITED" -eq 0 ]; then pass "job holds no agent socket/KV fds"; else fail "job inherited $INHERITED agent socket/KV fds"; fi

# 2. agent dies
kill -9 "$AGENT_PID"; wait "$AGENT_PID" 2>/dev/null
LINES_AT_KILL=$(log_lines)
if wait_for 1.5 grep -q "STATE agent_disconnected .*state=2" "$CLOG"; then pass "controller marked job agent_lost (<1.5s)"; else fail "no agent_lost state on controller within 1.5s"; fi
if kill -0 "$JOB_PID" 2>/dev/null; then pass "job process $JOB_PID survives agent kill"; else fail "job process died with the agent"; fi

# 3. controller dies while the agent is gone, restarts from persisted state
kill -9 "$CTL_PID"; wait "$CTL_PID" 2>/dev/null
start_controller
if wait_for 5 grep -q "restored $JOB state=2" "$CLOG"; then pass "controller restored serialized job state: $(grep "restored $JOB" "$CLOG" | tail -1 | sed 's/.*restored/restored/')"; else fail "controller did not restore job state"; fi
sleep 1
LINES_OFFLINE=$(log_lines)
if [ "$LINES_OFFLINE" -gt "$LINES_AT_KILL" ]; then pass "job progressed while agent offline ($LINES_AT_KILL -> $LINES_OFFLINE lines)"; else fail "job made no progress while agent offline"; fi

# 4. agent comes back and reattaches
start_agent
if wait "$CTL_PID"; then pass "controller exited after job completion"; else fail "controller exit status $?"; fi
wait_for 5 bash -c "! kill -0 $AGENT_PID 2>/dev/null"
kill "$AGENT_PID" 2>/dev/null

DONE_LINE=$(grep "STATE done" "$CLOG" | tail -1)
echo "final: ${DONE_LINE#*STATE }"
case "$DONE_LINE" in *"pid=$JOB_PID "*) pass "same job pid end to end";; *) fail "pid changed / missing";; esac
case "$DONE_LINE" in *"exit=3 "*) pass "exit code 3 delivered";; *) fail "exit code not delivered";; esac
case "$DONE_LINE" in *"disconnects=1"*) pass "one disconnect recorded";; *) fail "disconnect count wrong";; esac
if grep -q "reattach=$JOB" "$CLOG"; then pass "agent reattached to running job"; else fail "no reattach"; fi
if cmp -s "$JOBDIR/job.log" "$RUN/controller/$JOB.controller.log"; then pass "controller log identical to job log ($(wc -c < "$JOBDIR/job.log") bytes)"; else fail "log mismatch"; diff "$JOBDIR/job.log" "$RUN/controller/$JOB.controller.log" | head; fi
if [ "$(seq 1 $STEPS | sed 's/^/step /')" = "$(cat "$JOBDIR/job.log")" ]; then pass "job log complete and in order (steps 1..$STEPS)"; else fail "job log incomplete"; fi

echo "logs: $RUN"
if [ "$FAILS" -eq 0 ]; then echo "probe agent_disconnect PASS"; exit 0; fi
echo "probe agent_disconnect FAIL ($FAILS)"; exit 1
