#!/usr/bin/env bash
# Abnahme von REST-Gateway, Config as Code, API-Tokens, Rollen und kontor-Webhooks
# (doc/spec/111).  Ein Lauf, echte Prozesse: cosmosd + cosmos-api, Anfragen per curl.
#
#   ./run_e2e_api.sh             baut cosmosd + cosmos-api und prueft
#   ./run_e2e_api.sh --no-build  nimmt die vorhandenen Binaries
#
# Ablauf: zwei Konten anlegen, cosmosd anhalten, alice Freigabe 1 geben
# (Betriebshandlung bei gestopptem Dienst, F108-3), neu starten, dann alles ueber
# HTTP.  Braucht curl und python3 (fuer JSON und die HMAC des Webhooks).
set -uo pipefail
cd "$(dirname "$0")"
PROJ="$PWD"
LOGS="$PWD/logs"; mkdir -p "$LOGS"
WORK="$PWD/.e2e_api"; rm -rf "$WORK"; mkdir -p "$WORK"
WS_PORT=$((18900 + RANDOM % 50))
API_PORT=$((18960 + RANDOM % 30))
API="http://127.0.0.1:$API_PORT/api/v1"
FIX="$PROJ/test/fixtures/casc"

if [ "${1:-}" != "--no-build" ]; then
    # In einem Container liegt exodus woanders und steht schon auf PATH.
    [ -f ../../exvenv/bin/activate ] && source ../../exvenv/bin/activate
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    for cfg in exodus-cosmosd.json exodus-api.json; do
        exodus build -c "$cfg" || { echo "BUILD FAILED $cfg"; exit 1; }
    done
fi
# COSMOSD_BIN / COSMOS_API_BIN: andere Binaries pruefen (z. B. mit einer
# anderen aiml-Fassung gebaut), ohne die Vorgaben zu ueberschreiben.
cp "${COSMOSD_BIN:-cosmosd}" "$WORK/cosmosd"; cp "${COSMOS_API_BIN:-cosmos-api}" "$WORK/cosmos-api"
export AIONDB_PATH="$WORK/aiondb"

SRV_PID=""; API_PID=""
start_server() {
    ( cd "$WORK" && exec env COSMOS_BIND="ws://127.0.0.1:$WS_PORT" ./cosmosd > "$LOGS/e2e_api_srv$1.log" 2>&1 ) &
    SRV_PID=$!
    for _ in $(seq 1 80); do
        grep -q "listening on" "$LOGS/e2e_api_srv$1.log" 2>/dev/null && return 0
        sleep 0.25
    done
    echo "[api-e2e] cosmosd kam nicht hoch"; tail -5 "$LOGS/e2e_api_srv$1.log"; exit 1
}
stop_pid() {
    local pid="$1"; [ -z "$pid" ] && return
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || return; sleep 0.25; done
    kill -9 "$pid" 2>/dev/null
}
start_api() {
    ( cd "$WORK" && exec env COSMOS_API_PORT="$API_PORT" COSMOS_API_UPSTREAM="ws://127.0.0.1:$WS_PORT" ./cosmos-api > "$LOGS/e2e_api_gw.log" 2>&1 ) &
    API_PID=$!
    for _ in $(seq 1 80); do
        curl -s "$API/health" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    echo "[api-e2e] cosmos-api kam nicht hoch"; tail -5 "$LOGS/e2e_api_gw.log"; exit 1
}
cleanup() { stop_pid "$API_PID"; stop_pid "$SRV_PID"; }
trap cleanup EXIT

FAILS=0
# req METHOD PATH [TOKEN] [BODY] → setzt CODE und BODY
req() {
    local method="$1" path="$2" token="${3:-}" body="${4:-}"
    local args=(-s -o "$WORK/resp" -w "%{http_code}" -X "$method")
    [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
    [ -n "$body" ] && args+=(--data-binary "$body")
    CODE=$(curl "${args[@]}" "$API$path")
    BODY=$(cat "$WORK/resp")
}
expect() {  # expect WHAT WANT_CODE [GREP]
    local what="$1" want="$2" pat="${3:-}"
    if [ "$CODE" != "$want" ]; then
        echo "  FAIL $what: HTTP $CODE, erwartet $want — $BODY"; FAILS=$((FAILS+1)); return
    fi
    if [ -n "$pat" ] && ! grep -q -- "$pat" <<<"$BODY"; then
        echo "  FAIL $what: '$pat' fehlt in $BODY"; FAILS=$((FAILS+1)); return
    fi
    echo "  ok   $what"
}
field() { python3 -c "import json,sys; print(json.loads(sys.stdin.read())$1)" <<<"$BODY"; }
hook() {  # hook EVENT DELIVERY JSON [SECRET]
    local secret="${4:-$(cat "$FIX/secrets/hook.secret" | tr -d '\n')}"
    local sig; sig=$(python3 -c "import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest())" "$secret" "$3")
    CODE=$(curl -s -o "$WORK/resp" -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" -H "X-Kontor-Event: $1" -H "X-Kontor-Delivery: $2" \
        -H "X-Kontor-Signature-256: sha256=$sig" --data-binary "$3" "$API/hooks/kontor")
    BODY=$(cat "$WORK/resp")
}

echo "== Phase 1: Konten anlegen"
start_server 1
start_api
req GET /health; expect "health" 200 '"cosmosd":1'
req POST /register "" '{"email":"alice@example.org","password":"alice-pass-123","display_name":"alice"}'; expect "register alice" 201
req POST /register "" '{"email":"bob@example.org","password":"bob-pass-123","display_name":"bob"}'; expect "register bob" 201
stop_pid "$API_PID"; API_PID=""
stop_pid "$SRV_PID"; SRV_PID=""

echo "== Phase 2: alice Freigabe 1 (Dienst gestoppt)"
( cd "$WORK" && ./cosmosd --grant-email alice@example.org --grant-level 1 > "$LOGS/e2e_api_grant.log" 2>&1 ) || { echo "grant fehlgeschlagen"; cat "$LOGS/e2e_api_grant.log"; exit 1; }

echo "== Phase 3: REST"
WS_PORT=$((WS_PORT + 1))
start_server 2
start_api
req GET /whoami; expect "ohne Token → 401" 401 unauthenticated
req GET /whoami "nonsense"; expect "falsches Token → 401" 401
req POST /login "" '{"email":"alice@example.org","password":"wrong"}'; expect "falsches Passwort → 401" 401 login_failed
req POST /login "" '{"email":"alice@example.org","password":"alice-pass-123"}'; expect "login alice" 200 '"token"'
ALICE=$(field "['token']")
req POST /login "" '{"email":"bob@example.org","password":"bob-pass-123"}'; expect "login bob" 200
BOB=$(field "['token']")
req GET /whoami "$ALICE"; expect "whoami alice" 200 '"level":1'

# Config as Code: Plan beruehrt nichts, Apply setzt, Read zeigt.
req POST "/config/plan?path=$FIX/cosmos.yaml" "$ALICE"; expect "config plan" 200 '"success":1'
grep -q '"action":"add"' <<<"$BODY" && echo "  ok   plan nennt Zugaenge" || { echo "  FAIL plan ohne add: $BODY"; FAILS=$((FAILS+1)); }
req GET /config "$ALICE"; expect "config vor apply leer" 200
grep -q 'operator' <<<"$BODY" && { echo "  FAIL plan hat geschrieben: $BODY"; FAILS=$((FAILS+1)); } || echo "  ok   plan schrieb nichts"
req POST "/config/plan?path=$FIX/bad.yaml" "$ALICE"; expect "kaputte Erklaerung → 422" 422 '"success":0'
req POST "/config/apply?path=$FIX/cosmos.yaml" "$ALICE"; expect "config apply" 200 '"success":1'
req GET /config "$ALICE"; expect "config read" 200 'operator'
grep -q 'cat-core' <<<"$BODY" && echo "  ok   Katalog-Job cat-core" || { echo "  FAIL Katalog fehlt: $BODY"; FAILS=$((FAILS+1)); }
req POST "/config/plan?path=$FIX/cosmos.yaml" "$ALICE"; expect "zweiter Plan" 200
grep -q '"action":"add"' <<<"$BODY" && { echo "  FAIL Plan nach Apply nicht leer: $BODY"; FAILS=$((FAILS+1)); } || echo "  ok   Plan nach Apply ohne Zugaenge (idempotent)"
req GET /jobs "$ALICE"; expect "jobs" 200 'cat-zlib-lite'

# Rollen: bob hat keine Rolle → alles ausser Selbstbedienung 403.
req GET /whoami "$BOB"; expect "whoami bob (Selbstbedienung)" 200
req GET /cluster "$BOB"; expect "bob cluster → 403" 403
req POST "/config/plan?path=$FIX/cosmos.yaml" "$BOB"; expect "bob config → 403" 403

# API-Tokens
req POST /tokens "$ALICE" '{"label":"ci"}'; expect "token anlegen" 201 '"secret":"cosmos_'
API_TOK=$(field "['secret']"); TOK_ID=$(field "['token_id']")
grep -q "$API_TOK" "$LOGS"/e2e_api_srv2.log "$LOGS"/e2e_api_gw.log && { echo "  FAIL Geheimnis im Log"; FAILS=$((FAILS+1)); } || echo "  ok   Geheimnis steht in keinem Log"
req GET /whoami "$API_TOK"; expect "whoami per API-Token" 200 '"kind":"api_token"'
req GET /jobs "$API_TOK"; expect "jobs per API-Token" 200
req GET /tokens "$ALICE"; expect "tokens auflisten" 200 "$TOK_ID"
grep -q 'cosmos_' <<<"$BODY" && { echo "  FAIL Liste zeigt Geheimnis"; FAILS=$((FAILS+1)); } || echo "  ok   Liste ohne Geheimnis"

# kontor-Webhooks
req POST /hooks/kontor "" '{}'; expect "Webhook ohne Signatur → 401" 401
hook ping d-ping-1 '{"event":"ping","delivery":"d-ping-1","timestamp_ms":1,"kontor":"http://m","data":{}}'
expect "ping" 202 pong
hook ping d-ping-2 '{"event":"ping","delivery":"d-ping-2","timestamp_ms":1,"kontor":"http://m","data":{}}' "falsches-geheimnis-123"
expect "falsche Signatur → 401" 401
IMPACT='{"rebuild_count":2,"rebuild_waves":[["core"],["net"]],"needs":{"core":["zlib-lite"],"net":["core"]},"outdated_pins":[],"up_to_date":[],"cycles":[]}'
PUB='{"event":"package.published","delivery":"d-pub-1","timestamp_ms":2,"kontor":"http://m","data":{"name":"zlib-lite","version":"1.3.1","sha256":"ab","size":3,"unchanged":false,"impact":'"$IMPACT"'}}'
hook package.published d-pub-1 "$PUB"; expect "package.published oeffnet Kampagne" 202 Kampagne
hook package.published d-pub-1 "$PUB"; expect "gleiche Zustellung → duplicate" 202 duplicate
req GET /campaigns "$ALICE"; expect "campaigns" 200 '"trigger":"zlib-lite"'
CORE_STATE=$(python3 -c "import json,sys; c=json.loads(sys.stdin.read())['campaigns'][0]; print([i['state'] for i in c['items'] if i['project']=='core'][0])" <<<"$BODY")
NET_STATE=$(python3 -c "import json,sys; c=json.loads(sys.stdin.read())['campaigns'][0]; print([i['state'] for i in c['items'] if i['project']=='net'][0])" <<<"$BODY")
[ "$CORE_STATE" = running ] && echo "  ok   core laeuft (Welle 1)" || { echo "  FAIL core=$CORE_STATE"; FAILS=$((FAILS+1)); }
[ "$NET_STATE" = waiting ] && echo "  ok   net wartet auf core" || { echo "  FAIL net=$NET_STATE"; FAILS=$((FAILS+1)); }
# core veroeffentlicht byte-gleich → net braucht keinen Neubau.
PUB2='{"event":"package.published","delivery":"d-pub-2","timestamp_ms":3,"kontor":"http://m","data":{"name":"core","version":"2.0.0","sha256":"cd","size":3,"unchanged":true,"impact":null}}'
hook package.published d-pub-2 "$PUB2"; expect "core unveraendert" 202 fortgesetzt
req GET /campaigns "$ALICE"
python3 -c "
import json,sys
c=json.loads(sys.stdin.read())['campaigns'][0]
st={i['project']:i['state'] for i in c['items']}
assert st=={'core':'unchanged','net':'skipped'}, st
assert c['status']=='done', c['status']
" <<<"$BODY" && echo "  ok   net uebersprungen, Kampagne fertig" || { echo "  FAIL Kampagne: $BODY"; FAILS=$((FAILS+1)); }

# Widerruf
req DELETE "/tokens/$TOK_ID" "$ALICE"; expect "token widerrufen" 200
req GET /whoami "$API_TOK"; expect "widerrufenes Token → 401" 401
req POST /logout "$BOB"; expect "logout bob" 200
req GET /whoami "$BOB"; expect "nach logout → 401" 401

echo "== Phase 4: Erklaerung beim Start (COSMOS_CASC)"
stop_pid "$API_PID"; API_PID=""
stop_pid "$SRV_PID"; SRV_PID=""
WS_PORT=$((WS_PORT + 1))
( cd "$WORK" && COSMOS_CASC="$FIX/bad.yaml" COSMOS_BIND="ws://127.0.0.1:$WS_PORT" timeout 20 ./cosmosd > "$LOGS/e2e_api_srv3.log" 2>&1 )
if grep -q "listening on" "$LOGS/e2e_api_srv3.log"; then echo "  FAIL kaputte Erklaerung: cosmosd horcht trotzdem"; FAILS=$((FAILS+1));
else echo "  ok   kaputte Erklaerung verhindert den Start"; fi
( cd "$WORK" && exec env COSMOS_CASC="$FIX/cosmos.yaml" COSMOS_BIND="ws://127.0.0.1:$WS_PORT" ./cosmosd > "$LOGS/e2e_api_srv4.log" 2>&1 ) &
SRV_PID=$!
for _ in $(seq 1 80); do grep -q "listening on" "$LOGS/e2e_api_srv4.log" 2>/dev/null && break; sleep 0.25; done
grep -q "angewandt" "$LOGS/e2e_api_srv4.log" && echo "  ok   gueltige Erklaerung beim Start angewandt" || { echo "  FAIL Start mit Erklaerung"; tail -5 "$LOGS/e2e_api_srv4.log"; FAILS=$((FAILS+1)); }

echo
if [ "$FAILS" -eq 0 ]; then echo "E2E API: PASS"; exit 0; fi
echo "E2E API: $FAILS FAIL"; exit 1
