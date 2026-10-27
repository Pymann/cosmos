#!/usr/bin/env bash
# Kreist den cosmosd-Stillstand ein (doc/spec/110 §110.17).
#
# Misst im Takt, ob der Server einen WS-Handshake noch beantwortet, und haelt
# beim ERSTEN Nein fest, was in dem Moment gilt: Faeden, Sockets, Warteschlangen,
# Selbstverbindungen, offene Dateideskriptoren.  Danach laeuft er weiter, damit
# sichtbar wird, ob es sich wieder faengt.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="logs/hang_watch.log"
EVERY="${1:-10}"
PID="$(pgrep -x cosmosd | head -1)"
[ -n "$PID" ] || { echo "kein cosmosd" >&2; exit 1; }
echo "=== Beobachtung ab $(date +%H:%M:%S), cosmosd pid=$PID, Takt ${EVERY}s ===" >> "$OUT"

snapshot() {                       # $1 = Anlass
    {
        echo "--- $(date +%H:%M:%S)  $1 ---"
        echo "Faeden:      $(ls /proc/$PID/task 2>/dev/null | wc -l)"
        echo "fds:         $(ls /proc/$PID/fd 2>/dev/null | wc -l)"
        echo "wchan:       $(cat /proc/$PID/wchan 2>/dev/null)"
        echo "CPU-Ticks:   $(awk '{print $14+$15}' /proc/$PID/stat 2>/dev/null)"
        echo "Sockets auf 8765:"
        ss -tn state established '( sport = :8765 or dport = :8765 )' 2>/dev/null | tail -n +2 \
            | awk '{printf "  Recv-Q=%-7s Send-Q=%-7s %s -> %s\n", $1, $2, $3, $4}'
        echo "Selbstverbindungen (cosmosd als Client auf eigenem Port):"
        ss -tnp 2>/dev/null | grep ":8765" | grep "pid=$PID" | grep -v "^LISTEN" \
            | awk '{print "  ", $4, "->", $5, $6}'
        # Welcher Faden steckt wo?  (ohne root nur wchan, aber das genuegt)
        for T in /proc/$PID/task/*; do
            echo "  task $(basename $T): $(cat $T/wchan 2>/dev/null) | $(cat $T/stat 2>/dev/null | awk '{print $3}')"
        done
    } >> "$OUT" 2>&1
}

snapshot "START (Server antwortet noch nicht geprueft)"
CAUGHT=0
while kill -0 "$PID" 2>/dev/null; do
    if timeout 4 curl -s -o /dev/null --http1.1 \
         -H "Connection: Upgrade" -H "Upgrade: websocket" \
         -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
         "http://127.0.0.1:8765/" 2>/dev/null; then
        STATE="antwortet"
    else
        STATE="KEINE ANTWORT"
    fi
    printf '%s  %s\n' "$(date +%H:%M:%S)" "$STATE" >> "$OUT"
    if [ "$STATE" = "KEINE ANTWORT" ] && [ "$CAUGHT" -eq 0 ]; then
        CAUGHT=1
        snapshot "ERSTER STILLSTAND"
    fi
    sleep "$EVERY"
done
snapshot "cosmosd ist weg"
