#!/usr/bin/env bash
# Acceptance of the git connection (doc/spec/114) with real processes: a local
# repository served over git smart HTTP, cosmosd + cosmos-api, ufo, a stand-in for
# the GitHub status API and — when bwrap is there — an agent.
#
#   UFO_BIN=../ufo/ufo ./run_e2e_git.sh [--no-build]
#
#   1. from_repo reads the repository's ci/ at the head of main → job app-build
#   2. a signed push event for an OLDER commit → a run with THAT commit's pipeline
#      and prm.git_* values, and the status API gets `pending`
#   3. a bad signature is refused, a repeated delivery ignored, a fork pull
#      request and a deleted branch start nothing
#   4. with an agent: the run ends and the status API gets `success`
set -uo pipefail
cd "$(dirname "$0")"
PROJ="$PWD"
LOGS="$PWD/logs"; mkdir -p "$LOGS"
WORK="$PWD/.e2e_git"; rm -rf "$WORK"; mkdir -p "$WORK"
WS_PORT=$((19500 + RANDOM % 50))
API_PORT=$((19560 + RANDOM % 30))
GIT_PORT=$((19600 + RANDOM % 50))
GH_PORT=$((19660 + RANDOM % 30))
URL="ws://127.0.0.1:$WS_PORT"
API="http://127.0.0.1:$API_PORT/api/v1"
UFO_BIN="${UFO_BIN:-$PROJ/../ufo/ufo}"

if [ "${1:-}" != "--no-build" ]; then
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    for cfg in exodus-cosmosd.json exodus-api.json exodus-agent.json exodus-test-enroll.json; do
        aiml build -c "$cfg" || { echo "BUILD FAILED $cfg"; exit 1; }
    done
    if [ ! -x "$UFO_BIN" ] && [ -f "$PROJ/../ufo/exodus.json" ]; then
        ( cd "$PROJ/../ufo" && aiml build -c exodus.json ) || { echo "BUILD FAILED ufo"; exit 1; }
    fi
fi
[ -x "$UFO_BIN" ] || { echo "ufo not found: $UFO_BIN (set UFO_BIN)"; exit 2; }
cp cosmosd cosmos-api agent e2e_enroll "$WORK/"
cp "$UFO_BIN" "$WORK/ufo"
export AIONDB_PATH="$WORK/aiondb"

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT
FAILS=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS+1)); }
wait_for() { for _ in $(seq $(($1 * 4))); do eval "$2" && return 0; sleep 0.25; done; return 1; }

echo "== Repository"
G=(git -c user.email=e2e@example.org -c user.name=e2e)
mkdir -p "$WORK/src/ci" "$WORK/srv/demo"
cd "$WORK/src" && git init -q -b main .
cat > ci/build.aiml <<'AIML'
# pipeline: build
- pipeline:
    name: build
    steps:
      - stage: { name: first, run: "echo sha=${prm.git_sha} event=${prm.git_event} ref=${prm.git_ref}" }
AIML
# F114-13: the checkout is the step's, with ufo.  A step sees the host's /usr
# (doc/spec/91), so this stage is there only where a ufo under /usr runs in the
# sandbox — the agent's host has to bring it, as it brings sh.
UFO_IN_STEP=0
if command -v bwrap >/dev/null && bwrap --ro-bind /usr /usr --ro-bind /etc /etc --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 --symlink usr/bin /bin --proc /proc --dev /dev --tmpfs /tmp ufo init --bare /tmp/probe >/dev/null 2>&1; then
    UFO_IN_STEP=1
fi
if [ $UFO_IN_STEP = 1 ]; then cat >> ci/build.aiml <<'AIML'
      - stage: { name: checkout, run: "ufo clone ${prm.git_url} .repo && ufo -C .repo checkout-tree ${prm.git_sha} src && echo checked-out=$(grep -c 'name: first' src/ci/build.aiml)" }
AIML
fi
"${G[@]}" add -A && "${G[@]}" commit -qm one
OLD=$(git rev-parse HEAD)
sed -i 's/name: first/name: second/' ci/build.aiml
"${G[@]}" commit -qam two
NEW=$(git rev-parse HEAD)
git clone -q --bare . "$WORK/srv/demo/app.git"
cd "$PROJ"
( GIT_PROJECT_ROOT="$WORK/srv" exec python3 -I test/fixtures/git/githttp.py "$GIT_PORT" ) &
PIDS+=($!)
REPO="http://127.0.0.1:$GIT_PORT/demo/app.git"
wait_for 10 '"$WORK/ufo" ls-remote "$REPO" >/dev/null 2>&1' && ok "repository served over smart HTTP" || { fail "git server"; exit 1; }
( exec python3 -I test/fixtures/git/github_stub.py "$GH_PORT" "$WORK/statuses.jsonl" ) &
PIDS+=($!)

echo "== Start"
HOOK_SECRET="e2e-git-hook-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
GH_TOKEN_VALUE="ghs-e2e-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p "$WORK/casc"
printf '%s\n' "$HOOK_SECRET" > "$WORK/casc/hook.secret"
cat > "$WORK/casc/cosmos.yaml" <<YAML
- config:
    secrets:
      - secret: { name: gh_hook, file: hook.secret }
      - secret: { name: gh_token, env: E2E_GH_TOKEN }
    git: { webhook_secret: gh_hook, token: gh_token, api_url: "http://127.0.0.1:$GH_PORT", status: on }
- catalog:
    from_repo:
      - { url: "$REPO", branch: main, path: ci, triggers: [push, pull_request, tag] }
YAML
( cd "$WORK" && exec env E2E_GH_TOKEN="$GH_TOKEN_VALUE" COSMOS_UFO="$WORK/ufo" COSMOS_CASC="$WORK/casc/cosmos.yaml" COSMOS_BIND="$URL" ./cosmosd > "$LOGS/e2e_git_srv.log" 2>&1 ) &
PIDS+=($!)
wait_for 60 'grep -q "listening on" "$LOGS/e2e_git_srv.log"' || { echo "cosmosd did not come up"; tail -20 "$LOGS/e2e_git_srv.log"; exit 1; }
( cd "$WORK" && exec env COSMOS_API_PORT="$API_PORT" COSMOS_API_UPSTREAM="$URL" ./cosmos-api > "$LOGS/e2e_git_gw.log" 2>&1 ) &
PIDS+=($!)
wait_for 20 'curl -s -o /dev/null "$API/health"' || { echo "cosmos-api did not come up"; exit 1; }
ok "cosmosd and cosmos-api run"

curl -s -X POST --data-binary '{"email":"ops@example.org","password":"ops-pass-123","display_name":"ops"}' "$API/register" > "$WORK/reg.json"
OPS=$(python3 -c "import json; print(json.load(open('$WORK/reg.json'))['token'])")
AUTH=(-H "Authorization: Bearer $OPS")

echo "== Catalog (F114-2)"
curl -s "${AUTH[@]}" "$API/jobs" > "$WORK/jobs.json"
python3 - "$WORK/jobs.json" <<'PY' && ok "from_repo made job app-build from the head of main" || fail "no job app-build: $(head -c 400 "$WORK/jobs.json")"
import json, sys
d = json.load(open(sys.argv[1]))
jobs = d.get("jobs", d)
j = [x for x in jobs if x.get("name") == "app-build"]
sys.exit(0 if j and "second" in j[0].get("source", "") else 1)
PY

sign() { python3 -c "import hmac,hashlib,sys; print('sha256='+hmac.new(sys.argv[1].encode(), open(sys.argv[2],'rb').read(), hashlib.sha256).hexdigest())" "$HOOK_SECRET" "$1"; }
hook() {  # hook <event> <delivery> <body file> [signature]
    local sig="${4:-$(sign "$3")}"
    curl -s -o "$WORK/hook.json" -w "%{http_code}" -X POST -H "X-GitHub-Event: $1" -H "X-GitHub-Delivery: $2" \
        -H "X-Hub-Signature-256: $sig" -H "Content-Type: application/json" --data-binary @"$3" "$API/hooks/github"
}
push_body() { printf '{"ref":"%s","after":"%s","deleted":%s,"repository":{"full_name":"demo/app","clone_url":"%s"}}' "$1" "$2" "$3" "$REPO" > "$4"; }

echo "== Webhook (F114-6 … F114-9)"
echo '{"zen":"hi"}' > "$WORK/ping.json"
CODE=$(hook ping p-1 "$WORK/ping.json")
[ "$CODE" = 202 ] && grep -q pong "$WORK/hook.json" && ok "ping answered" || fail "ping: $CODE $(cat "$WORK/hook.json")"
push_body refs/heads/main "$OLD" false "$WORK/push.json"
CODE=$(hook push d-bad "$WORK/push.json" "sha256=0000")
[ "$CODE" = 401 ] && ok "a bad signature is refused (401)" || fail "bad signature: $CODE $(cat "$WORK/hook.json")"
CODE=$(hook push d-1 "$WORK/push.json")
[ "$CODE" = 202 ] && grep -q "fetching" "$WORK/hook.json" && ok "a signed push is taken: $(python3 -c "import json; print(json.load(open('$WORK/hook.json'))['outcome'])")" || fail "push: $CODE $(cat "$WORK/hook.json")"
CODE=$(hook push d-1 "$WORK/push.json")
grep -q duplicate "$WORK/hook.json" && ok "the same delivery again is ignored" || fail "duplicate: $CODE $(cat "$WORK/hook.json")"
push_body refs/heads/gone 0000000000000000000000000000000000000000 true "$WORK/del.json"
CODE=$(hook push d-2 "$WORK/del.json")
grep -q "ignored" "$WORK/hook.json" && ok "a deleted branch starts nothing" || fail "deleted: $CODE $(cat "$WORK/hook.json")"
printf '{"action":"opened","number":5,"pull_request":{"head":{"sha":"%s","repo":{"full_name":"stranger/app"}},"base":{"repo":{"full_name":"demo/app"}}},"repository":{"clone_url":"%s"}}' "$NEW" "$REPO" > "$WORK/fork.json"
CODE=$(hook pull_request d-3 "$WORK/fork.json")
grep -q "fork" "$WORK/hook.json" && ok "a fork pull request is not run" || fail "fork: $CODE $(cat "$WORK/hook.json")"

echo "== Run from the commit (F114-10, F114-11)"
runs() { curl -s "${AUTH[@]}" "$API/runs" > "$WORK/runs.json"; }
has_run() { python3 - "$WORK/runs.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
runs = d.get("pipelines", d.get("runs", d))
r = [x for x in runs if x.get("job_id") == "cat-app-build"]
names = [s.get("name", "") for x in r for s in x.get("stages", [])]
sys.exit(0 if any(sys.argv[2] in n for n in names) else 1)
PY
}
wait_for 30 'runs; has_run first' && ok "the run has the pipeline of the pushed commit (stage 'first', not 'second')" || fail "no run with stage first: $(head -c 600 "$WORK/runs.json")"
wait_for 15 'grep -q "\"pending\"" "$WORK/statuses.jsonl" 2>/dev/null' && ok "status API got pending" || fail "no pending status: $(cat "$WORK/statuses.jsonl" 2>/dev/null)"
grep -q "/repos/demo/app/statuses/$OLD" "$WORK/statuses.jsonl" 2>/dev/null && ok "for demo/app at the pushed commit" || fail "status path: $(head -1 "$WORK/statuses.jsonl" 2>/dev/null)"
grep -q "Bearer $GH_TOKEN_VALUE" "$WORK/statuses.jsonl" 2>/dev/null && ok "with the declared token" || fail "status without token"
grep -q '"cosmos/app-build"' "$WORK/statuses.jsonl" 2>/dev/null && ok "context cosmos/app-build" || fail "context: $(head -1 "$WORK/statuses.jsonl" 2>/dev/null)"

echo "== With an agent"
BWRAP="${COSMOS_BWRAP:-$(command -v bwrap || true)}"
if [ -z "$BWRAP" ]; then
    echo "  skip no bwrap here — the run stays queued (CI installs bubblewrap)"
else
    AGENT_TOKEN=$(cd "$WORK" && COSMOS_E2E_URL="$URL" ./e2e_enroll 2>"$LOGS/e2e_git_enroll.log")
    ( cd "$WORK" && exec env COSMOS_AGENT_TOKEN="$AGENT_TOKEN" ./agent --exec-url "$URL" --agent-id agent-git --bwrap-path "$BWRAP" > "$LOGS/e2e_git_agent.log" 2>&1 ) &
    PIDS+=($!)
    wait_for 60 'grep -q "\"success\"" "$WORK/statuses.jsonl" 2>/dev/null' && ok "the run ended: status API got success" || fail "no success status: $(cat "$WORK/statuses.jsonl")"
    OUT=$(grep -rh "sha=" "$WORK"/steps/*/*/out 2>/dev/null | head -1)
    [ "$OUT" = "sha=$OLD event=push ref=refs/heads/main" ] && ok "the step saw prm.git_*: $OUT" || fail "step output: '$OUT'"
    if [ $UFO_IN_STEP = 1 ]; then
        CO=$(grep -rh "checked-out=" "$WORK"/steps/*/*/out 2>/dev/null | head -1)
        [ "$CO" = "checked-out=1" ] && ok "F114-13: the step checked out the pushed commit with ufo" || fail "checkout step: '$CO' $(cat "$WORK"/steps/*/*/err 2>/dev/null | tail -3)"
    else
        echo "  skip no ufo under /usr that runs in the step sandbox — checkout in a step not tried"
    fi
fi

grep -q "$HOOK_SECRET\|$GH_TOKEN_VALUE" "$LOGS"/e2e_git_*.log && fail "a secret in the log" || ok "no secret in the log"
echo
if [ "$FAILS" -eq 0 ]; then echo "E2E GIT: PASS"; exit 0; fi
echo "E2E GIT: $FAILS FAIL"; exit 1
