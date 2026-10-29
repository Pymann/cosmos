#!/usr/bin/env bash
# Abnahme des Zusammenspiels mit museum (doc/spec/111 §111.6/§111.9) — echte Prozesse:
# museum (Registry + Webhooks), cosmosd + cosmos-api, cosmos-museum.
#
#   MUSEUM_DIR=../museum MUSEUM_AIML=aiml ./run_e2e_museum.sh [--no-build]
#
#   1. museum meldet sich per Webhook (ping) — cosmos prueft die Signatur
#   2. ein Paket wird in museum veroeffentlicht → museum schickt den Plan →
#      cosmos oeffnet eine Kampagne und startet Welle 1 (Katalog-Job)
#   3. das naechste Projekt veroeffentlicht → dieselbe Kampagne geht weiter
#   4. cosmos-museum laedt ein OCI-Layout hoch und holt es byte-gleich zurueck
#
# museum braucht eine aiml-Fassung mit den Zweigen aus museum/README.md
# (aiml `ecosystem/integration-memv3`).
set -uo pipefail
cd "$(dirname "$0")"
PROJ="$PWD"
MUSEUM_DIR="${MUSEUM_DIR:-$PROJ/../museum}"
MUSEUM_AIML="${MUSEUM_AIML:-aiml}"
LOGS="$PWD/logs"; mkdir -p "$LOGS"
WORK="$PWD/.e2e_museum"; rm -rf "$WORK"; mkdir -p "$WORK"
WS_PORT=$((19300 + RANDOM % 50))
API_PORT=$((19360 + RANDOM % 30))
M_PORT=$((19400 + RANDOM % 50))
API="http://127.0.0.1:$API_PORT/api/v1"
MUSEUM="http://127.0.0.1:$M_PORT"
[ -f "$MUSEUM_DIR/museum.aiml" ] || { echo "museum nicht gefunden: $MUSEUM_DIR (MUSEUM_DIR setzen)"; exit 2; }

if [ "${1:-}" != "--no-build" ]; then
    source ../../exvenv/bin/activate
    for cfg in exodus-cosmosd.json exodus-api.json exodus-museum-client.json; do
        exodus build -c "$cfg" || { echo "BUILD FAILED $cfg"; exit 1; }
    done
fi
cp "${COSMOSD_BIN:-cosmosd}" "$WORK/cosmosd"; cp "${COSMOS_API_BIN:-cosmos-api}" "$WORK/cosmos-api"
cp "${COSMOS_MUSEUM_BIN:-cosmos-museum}" "$WORK/cosmos-museum"
export AIONDB_PATH="$WORK/aiondb"

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
FAILS=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS+1)); }
wait_for() { for _ in $(seq $(($1 * 4))); do eval "$2" && return 0; sleep 0.25; done; return 1; }

# Geheimnisse: Webhook (museum ⇄ cosmos) und museum-Token (cosmos → museum).
HOOK_SECRET="e2e-webhook-secret-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
ADMIN_TOKEN="$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)"
mkdir -p "$WORK/casc/ci"
printf '%s\n' "$HOOK_SECRET" > "$WORK/casc/hook.secret"
cp "$PROJ/test/fixtures/casc/ci/core.aiml" "$WORK/casc/ci/core.aiml"
sed 's/core/net/g' "$PROJ/test/fixtures/casc/ci/core.aiml" > "$WORK/casc/ci/net.aiml"
cat > "$WORK/casc/cosmos.yaml" <<YAML
- config:
    secrets:
      - secret: { name: hook, file: hook.secret }
      - secret: { name: mtok, env: E2E_MUSEUM_TOKEN }
    museum: { url: "$MUSEUM", webhook_secret: hook, token: mtok }
- catalog:
    from_dir:
      - { path: ci, triggers: [museum] }
YAML

echo "== Start"
( cd "$MUSEUM_DIR" && exec env MUSEUM_ADMIN_TOKEN="$ADMIN_TOKEN" "$MUSEUM_AIML" museum.aiml -- "$M_PORT" "$WORK/museum-data" > "$LOGS/e2e_museum_m.log" 2>&1 ) &
PIDS+=($!)
( cd "$WORK" && exec env E2E_MUSEUM_TOKEN="$ADMIN_TOKEN" COSMOS_CASC="$WORK/casc/cosmos.yaml" COSMOS_BIND="ws://127.0.0.1:$WS_PORT" ./cosmosd > "$LOGS/e2e_museum_srv.log" 2>&1 ) &
PIDS+=($!)
wait_for 30 'grep -q "listening on" "$LOGS/e2e_museum_srv.log"' || { echo "cosmosd kam nicht hoch"; tail -5 "$LOGS/e2e_museum_srv.log"; exit 1; }
( cd "$WORK" && exec env COSMOS_API_PORT="$API_PORT" COSMOS_API_UPSTREAM="ws://127.0.0.1:$WS_PORT" ./cosmos-api > "$LOGS/e2e_museum_gw.log" 2>&1 ) &
PIDS+=($!)
wait_for 20 'curl -s -o /dev/null "$API/health"' || { echo "cosmos-api kam nicht hoch"; exit 1; }
wait_for 60 'curl -s -o /dev/null "$MUSEUM/api/health"' || { echo "museum kam nicht hoch"; tail -5 "$LOGS/e2e_museum_m.log"; exit 1; }
ok "museum, cosmosd, cosmos-api laufen"

# Ein Konto mit Freigabe 1 fuer die Lesefragen an cosmos.
curl -s -X POST --data-binary '{"email":"ops@example.org","password":"ops-pass-123","display_name":"ops"}' "$API/register" > "$WORK/reg.json"
OPS=$(python3 -c "import json; print(json.load(open('$WORK/reg.json'))['token'])")
campaigns() { curl -s -H "Authorization: Bearer $OPS" "$API/campaigns" > "$WORK/camp.json"; }
state_of() { python3 -c "
import json,sys
c=[c for c in json.load(open('$WORK/camp.json'))['campaigns'] if c['trigger']==sys.argv[1]]
print({i['project']:i['state'] for i in c[0]['items']}.get(sys.argv[2],'-') if c else 'keine')" "$1" "$2"; }
MA=(-H "Authorization: Bearer $ADMIN_TOKEN")

echo "== Webhook"
CODE=$(curl -s -o "$WORK/sub.json" -w "%{http_code}" "${MA[@]}" -X POST \
    -d "{\"url\":\"$API/hooks/museum\",\"secret\":\"$HOOK_SECRET\",\"events\":[\"*\"]}" "$MUSEUM/api/v1/webhooks")
[ "$CODE" = 201 ] && ok "museum: Webhook auf cosmos angelegt" || fail "Webhook anlegen: $CODE $(cat "$WORK/sub.json")"
SUB=$(python3 -c "import json; print(json.load(open('$WORK/sub.json'))['id'])" 2>/dev/null)
delivered() { curl -s "${MA[@]}" "$MUSEUM/api/v1/webhooks/$SUB/deliveries" > "$WORK/dl.json"; python3 -c "
import json,sys
d=json.load(open('$WORK/dl.json')); d=d.get('deliveries',d)
print(len([x for x in d if x.get('event')==sys.argv[1] and x.get('status')=='delivered']))" "$1"; }
wait_for 15 '[ "$(delivered ping)" -ge 1 ]' && ok "ping zugestellt (cosmos hat die Signatur angenommen)" || fail "ping nicht zugestellt: $(cat "$WORK/dl.json")"

echo "== Kampagne"
for f in "$MUSEUM_DIR"/tests/fixtures/*.exodus.json; do
    base=$(basename "$f" .exodus.json); name=${base%-*}; version=${base##*-}
    curl -s -o /dev/null "${MA[@]}" -X PUT --data-binary @"$f" "$MUSEUM/exodus/$name/$version/exodus.json"
done
printf 'zlib build\0\1' > "$WORK/z.bin"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "${MA[@]}" -X PUT --data-binary @"$WORK/z.bin" "$MUSEUM/exodus/zlib-lite/1.0.0/package")
[ "$CODE" = 201 ] && ok "zlib-lite 1.0.0 in museum veroeffentlicht" || fail "Paket: $CODE"
wait_for 20 'campaigns; [ "$(state_of zlib-lite core)" = running ]' && ok "Kampagne zlib-lite: core laeuft (Katalog-Job cat-core)" || fail "core: $(state_of zlib-lite core) — $(cat "$WORK/camp.json")"
[ "$(state_of zlib-lite net)" = waiting ] && ok "net wartet auf core" || fail "net: $(state_of zlib-lite net)"
[ "$(state_of zlib-lite legacy)" = waiting ] && ok "legacy wartet" || fail "legacy: $(state_of zlib-lite legacy)"
printf 'core build' > "$WORK/c.bin"
curl -s -o /dev/null "${MA[@]}" -X PUT --data-binary @"$WORK/c.bin" "$MUSEUM/exodus/core/1.0.0/package"
wait_for 20 'campaigns; [ "$(state_of zlib-lite core)" = published ]' && ok "core veroeffentlicht → Posten erledigt" || fail "core: $(state_of zlib-lite core)"
[ "$(state_of zlib-lite net)" = running ] && ok "dieselbe Kampagne startet net (Welle 2)" || fail "net: $(state_of zlib-lite net)"
[ "$(state_of zlib-lite legacy)" = no_job ] && ok "legacy ohne Katalog-Job → no_job" || fail "legacy: $(state_of zlib-lite legacy)"
N=$(python3 -c "import json; print(len(json.load(open('$WORK/camp.json'))['campaigns']))")
[ "$N" = 1 ] && ok "keine zweite Kampagne fuer core" || fail "$N Kampagnen"

echo "== Registry"
python3 "$MUSEUM_DIR/tests/fixtures/oci/make_layout.py" image "$WORK/layout" > "$WORK/img.digest"
PUSHED=$(cd "$WORK" && E2E_MUSEUM_TOKEN="$ADMIN_TOKEN" ./cosmos-museum --mode push --layout "$WORK/layout" --url "$MUSEUM" --ref e2e/app:v1 --token-env E2E_MUSEUM_TOKEN 2> "$WORK/push.log")
[ -n "$PUSHED" ] && ok "cosmos-museum push → $PUSHED" || fail "push: $(tail -3 "$WORK/push.log")"
PULLED=$(cd "$WORK" && ./cosmos-museum --mode pull --layout "$WORK/back" --url "$MUSEUM" --ref e2e/app:v1 2> "$WORK/pull.log")
[ "$PULLED" = "$PUSHED" ] && ok "pull (anonym lesend) liefert dieselbe Digest" || fail "pull: '$PULLED' — $(tail -3 "$WORK/pull.log")"
SAME=1
for b in "$WORK"/layout/blobs/sha256/*; do cmp -s "$b" "$WORK/back/blobs/sha256/$(basename "$b")" || SAME=0; done
[ $SAME = 1 ] && ok "alle Blobs byte-gleich zurueck" || fail "Blobs verschieden"
PULLED2=$(cd "$WORK" && ./cosmos-museum --mode pull --layout "$WORK/back" --url "$MUSEUM" --ref "e2e/app@$PUSHED" 2>> "$WORK/pull.log")
[ "$PULLED2" = "$PUSHED" ] && ok "pull per Digest" || fail "pull per Digest: '$PULLED2'"
NOAUTH=$(cd "$WORK" && ./cosmos-museum --mode push --layout "$WORK/layout" --url "$MUSEUM" --ref e2e/app:v2 2>/dev/null)
[ -z "$NOAUTH" ] && ok "push ohne Token abgewiesen" || fail "push ohne Token ging durch"
wait_for 10 '[ "$(delivered image.pushed)" -ge 1 ]' && ok "museum meldet image.pushed an cosmos" || fail "image.pushed nicht zugestellt"

grep -q "$HOOK_SECRET\|$ADMIN_TOKEN" "$LOGS"/e2e_museum_*.log "$WORK/push.log" "$WORK/pull.log" && fail "Geheimnis im Log" || ok "kein Geheimnis im Log"
echo
if [ "$FAILS" -eq 0 ]; then echo "E2E MUSEUM: PASS"; exit 0; fi
echo "E2E MUSEUM: $FAILS FAIL"; exit 1
