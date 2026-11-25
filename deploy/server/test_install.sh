#!/bin/bash
# Abnahme der Server-Einrichtung (doc/spec/112 §112.7) — auf einem frischen
# Ubuntu 24.04 mit systemd, das den kontor-Server spielt (CI-Job server-setup).
#
#   GH_TOKEN=… AIML_VENV=… deploy/server/test_install.sh
#
# Braucht: gebaute cosmosd, cosmos-api, agent im Repo; eine aiml-venv
# ($AIML_VENV); sudo; ein GitHub-Token mit Lesezugriff ($GH_TOKEN), weil die
# Pipeline den aiml-Tarball aus einem CI-Lauf von Pymann/aiml holt.
#
# VERAENDERT DEN RECHNER (Dienste, Nutzer, /opt/cosmos) — nur auf einem
# Wegwerf-Rechner ausfuehren.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
ROOT="$PWD"
WORK="$(mktemp -d)"; chmod 755 "$WORK"
STUB_PORT=18443
KURL="http://127.0.0.1:$STUB_PORT"
JOB=cat-aiml_to_kontor
FAILS=0
ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

[ -n "${AIML_VENV:-}" ] || { echo "AIML_VENV fehlt"; exit 2; }
[ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN fehlt"; exit 2; }

diagnose() {
    echo "::group::Diagnose"
    sudo journalctl -u cosmosd -u cosmos-api -u cosmos-agent --no-pager -n 200 || true
    sudo sh -c 'ls -la /var/lib/cosmos /var/lib/cosmos/run_logs; for f in /var/lib/cosmos/run_logs/*; do echo "=== $f"; tail -n 40 "$f"; done' 2>&1 || true
    sudo sh -c 'for f in /var/lib/cosmos-agent/steps/*/*/err; do [ -s "$f" ] || continue; echo "=== $f"; tail -n 20 "$f"; done' 2>&1 || true
    echo "--- kontor-Ersatz"; tail -n 40 "$WORK/stub.log" 2>/dev/null || true
    echo "::endgroup::"
}
STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; }
trap cleanup EXIT

runs_of() { sudo cosmosctl api GET /runs | jq -c --arg p aiml_to_kontor '[.runs[] | select(.pipeline_name == $p)]'; }
wait_run() {  # wait_run <run-id> → Status ausgeben
    local id="$1" st=""
    for _ in $(seq 1 360); do
        st="$(sudo cosmosctl api GET /runs | jq -r --arg id "$id" '.runs[] | select(.run_id == $id) | .status')"
        case "$st" in done|failed) echo "$st"; return 0 ;; esac
        sleep 5
    done
    echo "${st:-unbekannt}"
}

echo "== 1. kontor-Ersatz"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$WORK/kontor.token"
printf '%s\n' "$GH_TOKEN" > "$WORK/github.token"; chmod 600 "$WORK/github.token"
python3 "$ROOT/test/kontor_stub.py" "$STUB_PORT" "$WORK/kontor" "$WORK/kontor.token" > "$WORK/stub.log" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 40); do curl -fs "$KURL/api/v1/health" >/dev/null 2>&1 && break; sleep 0.25; done
check "kontor-Ersatz antwortet" curl -fs "$KURL/api/v1/health" -o /dev/null

echo "== 2. install.sh"
if ! sudo "$ROOT/deploy/server/install.sh" --venv "$AIML_VENV" --kontor-url "$KURL" \
        --kontor-token-file "$WORK/kontor.token" --github-token-file "$WORK/github.token"; then
    fail "install.sh"; diagnose; exit 1
fi
ok "install.sh"

echo "== 3. Dienste"
for u in cosmosd cosmos-api cosmos-agent; do check "$u aktiv" systemctl is-active --quiet "$u"; done
listen="$(sudo ss -ltnH)"
check "cosmosd horcht nur auf 127.0.0.1:8770" bash -c "grep -q '127.0.0.1:8770 ' <<<'$listen' && ! grep -qE '(0.0.0.0|\\*|\\[::\\]):8770 ' <<<'$listen'"
check "cosmos-api horcht nur auf 127.0.0.1:8771" bash -c "grep -q '127.0.0.1:8771 ' <<<'$listen' && ! grep -qE '(0.0.0.0|\\*|\\[::\\]):8771 ' <<<'$listen'"
jobs="$(sudo cosmosctl jobs)"; echo "$jobs" | sed 's/^/       /'
check "Katalog-Job $JOB, stuendlich" grep -q "^$JOB .*interval_s=3600" <<<"$jobs"
check "Geheimnisse 0600 root" bash -c '[ "$(sudo stat -c %a:%U /etc/cosmos/api.token)" = 600:root ] && [ "$(sudo stat -c %a:%U /etc/cosmos/admin.password)" = 600:root ]'
check "Agent-Token 0600 cosmos-agent" bash -c '[ "$(sudo stat -c %a:%U /var/lib/cosmos-agent/agent.token)" = 600:cosmos-agent ]'

echo "== 4. erster Lauf (der Zeitplan startet ihn sofort, F112-5)"
first=""
for _ in $(seq 1 30); do
    first="$(runs_of | jq -r 'sort_by(.started_ms) | .[0].run_id // empty')"
    [ -n "$first" ] && break; sleep 2
done
if [ -z "$first" ]; then
    echo "       kein geplanter Lauf nach 60 s — von Hand"
    first="$(sudo cosmosctl run "$JOB" | tail -1)"
fi
echo "       Lauf $first"
st="$(wait_run "$first")"
check "erster Lauf done (war: $st)" [ "$st" = "done" ]
latest="$WORK/kontor/generic/aiml/latest.env"
check "kontor hat aiml/latest.env" [ -f "$latest" ]
if [ -f "$latest" ]; then
    sed 's/^/       /' "$latest"
    tb="$(sed -n 's/^tarball=//p' "$latest")"; sum="$(sed -n 's/^sha256=//p' "$latest")"
    check "Tarball liegt in kontor" [ -f "$WORK/kontor/generic/$tb" ]
    check ".sha256 liegt in kontor" [ -f "$WORK/kontor/generic/$tb.sha256" ]
    check "Pruefsumme stimmt" bash -c "[ \"\$(sha256sum '$WORK/kontor/generic/$tb' | cut -d' ' -f1)\" = '$sum' ]"
    check "latest.env kam zuletzt (F112-10)" bash -c "tail -1 '$WORK/kontor/puts.log' | grep -q 'aiml/latest.env'"
fi

echo "== 5. zweiter Lauf laedt nichts (F112-11)"
puts_before="$(grep -c '\.tar\.gz ' "$WORK/kontor/puts.log" 2>/dev/null || echo 0)"
second="$(sudo cosmosctl run "$JOB" | tail -1)"
st="$(wait_run "$second")"
check "zweiter Lauf done (war: $st)" [ "$st" = "done" ]
check "kein zweiter PUT des Tarballs" [ "$(grep -c '\.tar\.gz ' "$WORK/kontor/puts.log" 2>/dev/null || echo 0)" = "$puts_before" ]
log2="$(sudo cosmosctl log "$second" 2>&1)"   # erst ganz lesen: grep -q schloesse die Pipe (pipefail)
if grep -q 'nichts zu tun' <<<"$log2"; then ok "Lauf meldet: kontor aktuell"; else fail "Lauf meldet nicht, dass kontor aktuell ist"; echo "$log2" | tail -n 20; fi

echo "== 6. setup-aiml.sh aus kontor (F112-14, STRICT)"
# Die Ablage, die aiml's eigene CI in kontor fuellt ("Put the bundle into
# kontor"): generic/aiml/latest/aiml-x86_64-linux.tar.gz, eine venv (bin lib
# env) ohne Huelle.  Gebaut wie dort, aus dem eben gespiegelten Tarball.
if [ -f "${latest:-}" ]; then
    bdir="$(mktemp -d)"; mkdir "$bdir/venv"
    tar -xzf "$WORK/kontor/generic/$tb" -C "$bdir/venv" --strip-components=1
    printf '%s\n' "# aiml venv" > "$bdir/venv/env"
    mkdir -p "$WORK/kontor/generic/aiml/latest"
    tar -czf "$WORK/kontor/generic/aiml/latest/aiml-x86_64-linux.tar.gz" -C "$bdir/venv" bin lib env
    rm -rf "$bdir"
fi
if env -u GITHUB_ENV -u GITHUB_PATH AIML_KONTOR_URL="$KURL" AIML_KONTOR_STRICT=1 \
        bash "$ROOT/.github/ci/setup-aiml.sh" "$WORK/venv2" > "$WORK/setup.log" 2>&1; then
    check "Quelle war kontor (latest)" grep -q "^aiml: kontor $KURL (latest, sha256 " "$WORK/setup.log"
    check "venv aus kontor fertig" [ -x "$WORK/venv2/bin/aiml" ]
else
    fail "setup-aiml.sh aus kontor"; tail -n 20 "$WORK/setup.log"
fi
check "unbekannter Schluessel → STRICT scheitert" bash -c "! env -u GITHUB_ENV -u GITHUB_PATH AIML_KONTOR_URL='$KURL' AIML_KONTOR_STRICT=1 AIML_RELEASE=v0.0.0-gibtsnicht bash '$ROOT/.github/ci/setup-aiml.sh' '$WORK/venv4' >/dev/null 2>&1"
check "kontor aus → Rueckfall mit Warnung" bash -c "env -u GITHUB_ENV -u GITHUB_PATH AIML_KONTOR_URL=http://127.0.0.1:1 bash '$ROOT/.github/ci/setup-aiml.sh' '$WORK/venv3' 2>&1 | grep -q 'falling back to GitHub'"

echo "== 7. Was ein Schritt sieht (F112-2, F112-6)"
probe='- pipeline:
    name: sicht_probe
    steps:
      - stage:
          name: sicht
          timeout: 60000
          run: "set -e; ! cat /etc/cosmos/api.token 2>/dev/null; ! cat /etc/cosmos/admin.password 2>/dev/null; ! ls /var/lib/cosmos 2>/dev/null; ! cat /var/lib/cosmos-agent/agent.token 2>/dev/null; test -r /etc/cosmos-agent/kontor.env; test -x /usr/local/libexec/cosmos/kontor-blob; env; echo sicht-ok"'
resp="$(sudo cosmosctl api POST /pipelines/run "$probe")"
pid="$(jq -r '.run_id // empty' <<<"$resp")"
if [ -n "$pid" ]; then
    st="$(wait_run "$pid")"
    check "Schritt liest weder API-Token, Admin-Passwort, KV noch Agent-Token, aber kontor.env (war: $st)" [ "$st" = "done" ]
else
    fail "Probe-Pipeline abgelehnt: $resp"
fi
agent_tok="$(sudo cat /var/lib/cosmos-agent/agent.token)"
if sudo grep -rqF "$agent_tok" /var/lib/cosmos-agent/steps /var/lib/cosmos/run_logs 2>/dev/null; then
    fail "Agent-Token steht in einer Schritt-Ausgabe"
else
    ok "Agent-Token in keiner Schritt-Ausgabe"
fi

echo "== 8. install.sh ein zweites Mal (idempotent)"
before="$(sudo sha256sum /etc/cosmos/api.token /etc/cosmos/admin.password /var/lib/cosmos-agent/agent.token)"
# shellcheck disable=SC2024  # das Protokoll gehoert dem Aufrufer, nicht root
if sudo "$ROOT/deploy/server/install.sh" --venv "$AIML_VENV" > "$WORK/install2.log" 2>&1; then
    ok "zweiter Lauf von install.sh"
else
    fail "zweiter Lauf von install.sh"; tail -n 30 "$WORK/install2.log"
fi
check "Tokens und Passwort unveraendert" [ "$before" = "$(sudo sha256sum /etc/cosmos/api.token /etc/cosmos/admin.password /var/lib/cosmos-agent/agent.token)" ]
check "kontor-URL bleibt (ohne --kontor-url)" sudo grep -q "^KONTOR_URL=$KURL$" /etc/cosmos-agent/kontor.env
for u in cosmosd cosmos-api cosmos-agent; do check "$u wieder aktiv" systemctl is-active --quiet "$u"; done
third="$(sudo cosmosctl run "$JOB" | tail -1)"
st="$(wait_run "$third")"
check "Lauf nach Neuinstallation done (war: $st)" [ "$st" = "done" ]

echo
if [ "$FAILS" -eq 0 ]; then echo "SERVER-SETUP: PASS"; exit 0; fi
diagnose
echo "SERVER-SETUP: $FAILS FAIL"; exit 1
