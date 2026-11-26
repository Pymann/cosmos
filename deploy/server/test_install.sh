#!/bin/bash
# Abnahme der Server-Einrichtung (doc/spec/112 §112.7) — auf einem frischen
# Ubuntu 24.04 mit systemd, das den kontor-Server spielt (CI-Job server-setup).
#
#   AIML_VENV=… [GH_TOKEN=…] deploy/server/test_install.sh
#
# Braucht: gebaute cosmosd, cosmos-api, agent im Repo; eine aiml-venv
# ($AIML_VENV); sudo.  GH_TOKEN nur fuer den Rueckfall von setup-aiml.sh auf
# GitHub (Schritt 5).
#
# VERAENDERT DEN RECHNER (Dienste, Nutzer, /opt/cosmos) — nur auf einem
# Wegwerf-Rechner ausfuehren.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
ROOT="$PWD"
WORK="$(mktemp -d)"; chmod 755 "$WORK"
STUB_PORT=18443
KURL="http://127.0.0.1:$STUB_PORT"
JOB=cat-blob_probe
FAILS=0
ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

[ -n "${AIML_VENV:-}" ] || { echo "AIML_VENV fehlt"; exit 2; }

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
python3 "$ROOT/test/kontor_stub.py" "$STUB_PORT" "$WORK/kontor" "$WORK/kontor.token" > "$WORK/stub.log" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 40); do curl -fs "$KURL/api/v1/health" >/dev/null 2>&1 && break; sleep 0.25; done
check "kontor-Ersatz antwortet" curl -fs "$KURL/api/v1/health" -o /dev/null

# Eine eigene Pipeline des Betreibers (from_dir, §112.5) und die Ueberbleibsel
# einer frueheren Fassung (F112-16), so wie sie nach einem Update daliegen.
sudo install -d -m 0755 /etc/cosmos/pipelines /usr/local/libexec/cosmos
sudo install -d -m 0750 /etc/cosmos-agent
sudo tee /etc/cosmos/pipelines/blob_probe.yaml >/dev/null <<'YAML'
# project: cosmos
- pipeline:
    name: blob_probe
    steps:
      - stage:
          name: blob
          requires: [curl, sha256sum]
          timeout: 120000
          run: "set -e; head -c 4096 /dev/urandom > probe.bin; /usr/local/libexec/cosmos/kontor-blob put probe.bin probe/blob.bin; /usr/local/libexec/cosmos/kontor-blob has probe/blob.bin; /usr/local/libexec/cosmos/kontor-blob get probe/blob.bin back.bin; cmp probe.bin back.bin; ! /usr/local/libexec/cosmos/kontor-blob has probe/fehlt.bin; sha256sum probe.bin; echo blob-ok"
YAML
echo '- pipeline: { name: aiml_to_kontor, steps: [ { stage: { name: alt, run: "false" } } ] }' | sudo tee /etc/cosmos/pipelines/aiml_to_kontor.yaml >/dev/null
printf '#!/bin/sh\nexit 1\n' | sudo tee /usr/local/libexec/cosmos/aiml-mirror >/dev/null
echo '#AIML_REPO=Pymann/aiml' | sudo tee /etc/cosmos-agent/aiml.env >/dev/null

echo "== 2. install.sh"
if ! sudo "$ROOT/deploy/server/install.sh" --venv "$AIML_VENV" --kontor-url "$KURL" \
        --kontor-token-file "$WORK/kontor.token"; then
    fail "install.sh"; diagnose; exit 1
fi
ok "install.sh"

echo "== 3. Dienste"
for u in cosmosd cosmos-api cosmos-agent; do check "$u aktiv" systemctl is-active --quiet "$u"; done
listen="$(sudo ss -ltnH)"
check "cosmosd horcht nur auf 127.0.0.1:8770" bash -c "grep -q '127.0.0.1:8770 ' <<<'$listen' && ! grep -qE '(0.0.0.0|\\*|\\[::\\]):8770 ' <<<'$listen'"
check "cosmos-api horcht nur auf 127.0.0.1:8771" bash -c "grep -q '127.0.0.1:8771 ' <<<'$listen' && ! grep -qE '(0.0.0.0|\\*|\\[::\\]):8771 ' <<<'$listen'"
jobs="$(sudo cosmosctl jobs)"; echo "$jobs" | sed 's/^/       /'
check "eigene Pipeline ist Katalog-Job $JOB (from_dir)" grep -q "^$JOB " <<<"$jobs"
check "kein Job cat-aiml_to_kontor (F112-13)" bash -c "! grep -q '^cat-aiml_to_kontor ' <<<'$jobs'"
for old in /etc/cosmos/pipelines/aiml_to_kontor.yaml /usr/local/libexec/cosmos/aiml-mirror /etc/cosmos-agent/aiml.env; do
    check "Ueberbleibsel entfernt: $old (F112-16)" sudo test ! -e "$old"
done
check "Geheimnisse 0600 root" bash -c '[ "$(sudo stat -c %a:%U /etc/cosmos/api.token)" = 600:root ] && [ "$(sudo stat -c %a:%U /etc/cosmos/admin.password)" = 600:root ]'
check "Agent-Token 0600 cosmos-agent" bash -c '[ "$(sudo stat -c %a:%U /var/lib/cosmos-agent/agent.token)" = 600:cosmos-agent ]'

echo "== 4. Pipeline legt mit kontor-blob ab (§112.5)"
run1="$(sudo cosmosctl run "$JOB" | tail -1)"
echo "       Lauf $run1"
st="$(wait_run "$run1")"
check "Lauf $JOB done (war: $st)" [ "$st" = "done" ]
blob="$WORK/kontor/generic/probe/blob.bin"
check "kontor hat probe/blob.bin" [ -f "$blob" ]
if [ -f "$blob" ]; then
    sum="$(sha256sum "$blob" | cut -d' ' -f1)"
    check "PUT mit Pruefsumme im Protokoll des kontor-Ersatzes" grep -q "^PUT /generic/probe/blob.bin $sum$" "$WORK/kontor/puts.log"
    log1="$(sudo cosmosctl log "$run1" 2>&1)"   # erst ganz lesen: grep -q schloesse die Pipe (pipefail)
    check "der Schritt hat dieselbe Datei hochgeladen" grep -q "$sum" <<<"$log1"
fi

echo "== 5. setup-aiml.sh aus kontor (F112-14, STRICT)"
# Die Ablage, die aiml's eigene CI in kontor fuellt ("Put the bundle into
# kontor"): generic/aiml/latest/aiml-x86_64-linux.tar.gz, eine venv (bin lib
# env) ohne Huelle.  Gebaut wie dort, aus der venv dieses Laufs.
mkdir -p "$WORK/kontor/generic/aiml/latest"
tar -czf "$WORK/kontor/generic/aiml/latest/aiml-x86_64-linux.tar.gz" -C "$AIML_VENV" bin lib env
if env -u GITHUB_ENV -u GITHUB_PATH AIML_KONTOR_URL="$KURL" AIML_KONTOR_STRICT=1 \
        bash "$ROOT/.github/ci/setup-aiml.sh" "$WORK/venv2" > "$WORK/setup.log" 2>&1; then
    check "Quelle war kontor (latest)" grep -q "^aiml: kontor $KURL (latest, sha256 " "$WORK/setup.log"
    check "venv aus kontor fertig" [ -x "$WORK/venv2/bin/aiml" ]
else
    fail "setup-aiml.sh aus kontor"; tail -n 20 "$WORK/setup.log"
fi
check "unbekannter Schluessel → STRICT scheitert" bash -c "! env -u GITHUB_ENV -u GITHUB_PATH AIML_KONTOR_URL='$KURL' AIML_KONTOR_STRICT=1 AIML_RELEASE=v0.0.0-gibtsnicht bash '$ROOT/.github/ci/setup-aiml.sh' '$WORK/venv4' >/dev/null 2>&1"
check "kontor aus → Rueckfall mit Warnung" bash -c "env -u GITHUB_ENV -u GITHUB_PATH AIML_KONTOR_URL=http://127.0.0.1:1 bash '$ROOT/.github/ci/setup-aiml.sh' '$WORK/venv3' 2>&1 | grep -q 'falling back to GitHub'"

echo "== 6. Was ein Schritt sieht (F112-2, F112-6)"
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

echo "== 7. install.sh ein zweites Mal (idempotent)"
before="$(sudo sha256sum /etc/cosmos/api.token /etc/cosmos/admin.password /var/lib/cosmos-agent/agent.token)"
# shellcheck disable=SC2024  # das Protokoll gehoert dem Aufrufer, nicht root
if sudo "$ROOT/deploy/server/install.sh" --venv "$AIML_VENV" > "$WORK/install2.log" 2>&1; then
    ok "zweiter Lauf von install.sh"
else
    fail "zweiter Lauf von install.sh"; tail -n 30 "$WORK/install2.log"
fi
check "Tokens und Passwort unveraendert" [ "$before" = "$(sudo sha256sum /etc/cosmos/api.token /etc/cosmos/admin.password /var/lib/cosmos-agent/agent.token)" ]
check "eigene Pipeline steht noch" sudo test -f /etc/cosmos/pipelines/blob_probe.yaml
check "kontor-URL bleibt (ohne --kontor-url)" sudo grep -q "^KONTOR_URL=$KURL$" /etc/cosmos-agent/kontor.env
for u in cosmosd cosmos-api cosmos-agent; do check "$u wieder aktiv" systemctl is-active --quiet "$u"; done
third="$(sudo cosmosctl run "$JOB" | tail -1)"
st="$(wait_run "$third")"
check "Lauf nach Neuinstallation done (war: $st)" [ "$st" = "done" ]

echo
if [ "$FAILS" -eq 0 ]; then echo "SERVER-SETUP: PASS"; exit 0; fi
diagnose
echo "SERVER-SETUP: $FAILS FAIL"; exit 1
