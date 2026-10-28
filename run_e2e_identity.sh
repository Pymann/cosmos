#!/usr/bin/env bash
# Abnahme der Anmeldung ueber LDAP und SAML (doc/spec/111 §111.5) — echte Prozesse:
# ein Wegwerf-slapd, cosmosd mit einer Erklaerung (COSMOS_CASC), cosmos-api, curl.
#
#   ./run_e2e_identity.sh             baut cosmosd + cosmos-api und prueft
#   ./run_e2e_identity.sh --no-build  nimmt die vorhandenen Binaries
#
# Braucht slapd/slapadd/slappasswd (OpenLDAP), openssl, xmlsec1 und python3 —
# die beiden letzten nur, um eine signierte SAML-Antwort zu ERZEUGEN (der IdP-Teil).
# Fehlt slapd oder xmlsec1, wird der jeweilige Teil uebersprungen (mit Hinweis).
set -uo pipefail
cd "$(dirname "$0")"
PROJ="$PWD"
LOGS="$PWD/logs"; mkdir -p "$LOGS"
WORK="$PWD/.e2e_identity"; rm -rf "$WORK"; mkdir -p "$WORK"
WS_PORT=$((19100 + RANDOM % 50))
API_PORT=$((19160 + RANDOM % 30))
LDAP_PORT=$((19200 + RANDOM % 50))
API="http://127.0.0.1:$API_PORT/api/v1"

if [ "${1:-}" != "--no-build" ]; then
    source ../../exvenv/bin/activate
    for cfg in exodus-cosmosd.json exodus-api.json; do
        exodus build -c "$cfg" || { echo "BUILD FAILED $cfg"; exit 1; }
    done
fi
# COSMOSD_BIN / COSMOS_API_BIN: andere Binaries pruefen (z. B. mit einer
# anderen aiml-Fassung gebaut), ohne die Vorgaben zu ueberschreiben.
cp "${COSMOSD_BIN:-cosmosd}" "$WORK/cosmosd"; cp "${COSMOS_API_BIN:-cosmos-api}" "$WORK/cosmos-api"
export AIONDB_PATH="$WORK/aiondb"

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; [ -f "$WORK/slapd.pid" ] && kill "$(cat "$WORK/slapd.pid")" 2>/dev/null; }
trap cleanup EXIT
FAILS=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS+1)); }

# ── LDAP: Wegwerf-Verzeichnis ────────────────────────────────────────────────
HAVE_LDAP=1
SLAPD="$(command -v slapd || echo /usr/sbin/slapd)"
[ -x "$SLAPD" ] || { echo "(slapd fehlt — LDAP-Teil uebersprungen)"; HAVE_LDAP=0; }
if [ $HAVE_LDAP = 1 ]; then
    mkdir -p "$WORK/ldapdb"
    MODLINE=""
    [ -e /usr/lib/ldap/back_mdb.so ] && MODLINE="modulepath /usr/lib/ldap
moduleload back_mdb"
    cat > "$WORK/slapd.conf" <<CONF
include /etc/ldap/schema/core.schema
include /etc/ldap/schema/cosine.schema
include /etc/ldap/schema/inetorgperson.schema
pidfile $WORK/slapd.pid
$MODLINE
database mdb
maxsize 10485760
suffix "dc=example,dc=org"
rootdn "cn=admin,dc=example,dc=org"
rootpw admin-secret
directory $WORK/ldapdb
access to attrs=userPassword by anonymous auth by * none
access to * by * read
CONF
    SP="$(command -v slappasswd || echo /usr/sbin/slappasswd)"
    A_PW=$("$SP" -s 'alice-pw'); B_PW=$("$SP" -s 'bob-pw')
    # Gruppen am Nutzereintrag: `businessCategory` statt `memberOf` — memberOf
    # braucht das memberof-Overlay, das ein Wegwerf-slapd nicht hat.
    cat > "$WORK/data.ldif" <<LDIF
dn: dc=example,dc=org
objectClass: dcObject
objectClass: organization
o: Example
dc: example

dn: ou=people,dc=example,dc=org
objectClass: organizationalUnit
ou: people

dn: uid=alice,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: alice
cn: Alice Example
sn: Example
mail: alice@example.org
businessCategory: cn=devs,ou=groups,dc=example,dc=org
userPassword: $A_PW

dn: uid=bob,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: bob
cn: Bob Example
sn: Example
mail: bob@example.org
userPassword: $B_PW
LDIF
    "$(command -v slapadd || echo /usr/sbin/slapadd)" -f "$WORK/slapd.conf" -l "$WORK/data.ldif" > "$WORK/slapadd.log" 2>&1 || { echo "slapadd scheiterte"; cat "$WORK/slapadd.log"; exit 1; }
    "$SLAPD" -f "$WORK/slapd.conf" -h "ldap://127.0.0.1:$LDAP_PORT/" > "$WORK/slapd.log" 2>&1
    for _ in $(seq 50); do [ -f "$WORK/slapd.pid" ] && break; sleep 0.1; done
    [ -f "$WORK/slapd.pid" ] || { echo "slapd startete nicht"; cat "$WORK/slapd.log"; exit 1; }
fi

# ── SAML: ein Schluessel fuer den gespielten IdP ─────────────────────────────
HAVE_SAML=1
command -v xmlsec1 >/dev/null || { echo "(xmlsec1 fehlt — SAML-Teil uebersprungen)"; HAVE_SAML=0; }
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=e2e-idp" -keyout "$WORK/idp_key.pem" -out "$WORK/idp_cert.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=evil-idp" -keyout "$WORK/evil_key.pem" -out "$WORK/evil_cert.pem" 2>/dev/null
ACS="http://127.0.0.1:$API_PORT/api/v1/sso/saml/acs"

cat > "$WORK/cosmos.yaml" <<YAML
- config:
    roles:
      - role: { name: viewer, may: [get_cluster] }
    grants:
      - grant: { group: devs, role: viewer }
    ldap:
      url: "ldap://127.0.0.1:$LDAP_PORT"
      user_dn: "uid={user},ou=people,dc=example,dc=org"
      group_attr: businessCategory
    saml:
      idp_sso_url: "https://idp.example/sso"
      idp_cert_file: idp_cert.pem
      sp_entity_id: "https://cosmos.example/sp"
      acs_url: "$ACS"
      idp_entity_id: "https://idp.example"
      group_attr: groups
YAML

( cd "$WORK" && exec env COSMOS_CASC="$WORK/cosmos.yaml" COSMOS_BIND="ws://127.0.0.1:$WS_PORT" ./cosmosd > "$LOGS/e2e_id_srv.log" 2>&1 ) &
PIDS+=($!)
for _ in $(seq 80); do grep -q "listening on" "$LOGS/e2e_id_srv.log" 2>/dev/null && break; sleep 0.25; done
grep -q "listening on" "$LOGS/e2e_id_srv.log" || { echo "cosmosd kam nicht hoch"; tail -5 "$LOGS/e2e_id_srv.log"; exit 1; }
( cd "$WORK" && exec env COSMOS_API_PORT="$API_PORT" COSMOS_API_UPSTREAM="ws://127.0.0.1:$WS_PORT" ./cosmos-api > "$LOGS/e2e_id_gw.log" 2>&1 ) &
PIDS+=($!)
for _ in $(seq 80); do curl -s "$API/health" >/dev/null 2>&1 && break; sleep 0.25; done

req() {  # req METHOD PATH TOKEN BODY
    local args=(-s -o "$WORK/resp" -w "%{http_code}" -X "$1")
    [ -n "${3:-}" ] && args+=(-H "Authorization: Bearer $3")
    [ -n "${4:-}" ] && args+=(--data-binary "$4")
    CODE=$(curl "${args[@]}" "$API$2"); BODY=$(cat "$WORK/resp")
}
token_of() { python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('token',''))" <<<"$BODY"; }

if [ $HAVE_LDAP = 1 ]; then
    echo "== LDAP"
    req POST /login "" '{"email":"alice","password":"alice-pw"}'
    [ "$CODE" = 200 ] && ok "alice per LDAP angemeldet" || fail "alice: HTTP $CODE $BODY"
    ALICE=$(token_of)
    grep -q '"email":"alice@example.org"' <<<"$BODY" && ok "E-Mail aus dem Verzeichnis (mail)" || fail "E-Mail: $BODY"
    req GET /cluster "$ALICE"; [ "$CODE" = 200 ] && ok "alice (Gruppe devs → viewer) liest den Cluster" || fail "alice cluster: $CODE $BODY"
    req POST /login "" '{"email":"bob","password":"bob-pw"}'; BOB=$(token_of)
    [ "$CODE" = 200 ] && ok "bob per LDAP angemeldet" || fail "bob: $CODE $BODY"
    req GET /cluster "$BOB"; [ "$CODE" = 403 ] && ok "bob ohne Gruppe → 403" || fail "bob cluster: $CODE"
    req POST /login "" '{"email":"alice","password":"falsch"}'; [ "$CODE" = 401 ] && ok "falsches Passwort → 401" || fail "falsch: $CODE"
    req POST /login "" '{"email":"alice","password":""}'; [ "$CODE" = 401 ] && ok "leeres Passwort → 401 (kein unauthenticated bind)" || fail "leer: $CODE"
    req POST /login "" '{"email":"*","password":"alice-pw"}'; [ "$CODE" = 401 ] && ok "Login '*' → 401 (escape_dn)" || fail "stern: $CODE"
    req POST /login "" '{"email":"alice","password":"alice-pw"}'
    grep -q '"email":"alice@example.org"' <<<"$BODY" && ok "zweite Anmeldung: dasselbe Konto" || fail "zweite: $BODY"
fi

if [ $HAVE_SAML = 1 ]; then
    echo "== SAML"
    LOC=$(curl -s -o /dev/null -w "%{redirect_url}" "$API/sso/saml/login?relay=/ui")
    case "$LOC" in https://idp.example/sso\?SAMLRequest=*) ok "302 zum IdP mit SAMLRequest";; *) fail "login-Umleitung: '$LOC'";; esac
    RID=$(python3 - "$LOC" <<'PY'
import sys, urllib.parse, base64, zlib, re
q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
xml = zlib.decompress(base64.b64decode(q["SAMLRequest"][0]), -15).decode()
print(re.search(r'ID="([^"]+)"', xml).group(1))
PY
)
    [ -n "$RID" ] && ok "Anfrage-Kennung $RID" || fail "keine Kennung"
    make_resp() {  # make_resp <request_id> <key> <out.b64> [<name_id>]
        python3 - "$1" "$ACS" "${4:-carol@example.org}" > "$WORK/resp.tmpl.xml" <<'PY'
import sys
rid, acs, who = sys.argv[1], sys.argv[2], sys.argv[3]
sig = ('<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:SignedInfo>'
       '<ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>'
       '<ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/>'
       '<ds:Reference URI="#_a1"><ds:Transforms>'
       '<ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>'
       '<ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/></ds:Transforms>'
       '<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue></ds:DigestValue></ds:Reference>'
       '</ds:SignedInfo><ds:SignatureValue></ds:SignatureValue><ds:KeyInfo><ds:X509Data/></ds:KeyInfo></ds:Signature>')
print('<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" '
      f'ID="_r1" Version="2.0" IssueInstant="2026-10-27T20:00:00Z" Destination="{acs}" InResponseTo="{rid}">'
      '<saml:Issuer>https://idp.example</saml:Issuer>'
      '<samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>'
      '<saml:Assertion ID="_a1" Version="2.0" IssueInstant="2026-10-27T20:00:00Z"><saml:Issuer>https://idp.example</saml:Issuer>'
      + sig +
      f'<saml:Subject><saml:NameID>{who}</saml:NameID><saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">'
      f'<saml:SubjectConfirmationData InResponseTo="{rid}" NotOnOrAfter="2099-01-01T00:00:00Z" Recipient="{acs}"/></saml:SubjectConfirmation></saml:Subject>'
      '<saml:Conditions NotBefore="2020-01-01T00:00:00Z" NotOnOrAfter="2099-01-01T00:00:00Z"><saml:AudienceRestriction>'
      '<saml:Audience>https://cosmos.example/sp</saml:Audience></saml:AudienceRestriction></saml:Conditions>'
      '<saml:AuthnStatement AuthnInstant="2026-10-27T20:00:00Z" SessionIndex="_s1"><saml:AuthnContext><saml:AuthnContextClassRef>'
      'urn:oasis:names:tc:SAML:2.0:ac:classes:Password</saml:AuthnContextClassRef></saml:AuthnContext></saml:AuthnStatement>'
      '<saml:AttributeStatement><saml:Attribute Name="groups"><saml:AttributeValue>devs</saml:AttributeValue></saml:Attribute>'
      '</saml:AttributeStatement></saml:Assertion></samlp:Response>')
PY
        local key="$2" cert="${2%_key.pem}_cert.pem"
        xmlsec1 --sign --privkey-pem "$key,$cert" --id-attr:ID urn:oasis:names:tc:SAML:2.0:assertion:Assertion \
            --output "$WORK/resp.xml" "$WORK/resp.tmpl.xml" 2>/dev/null || { echo "xmlsec1 sign scheiterte"; return 1; }
        base64 -w 0 "$WORK/resp.xml" > "$3"
    }
    post_acs() {  # post_acs <b64-file> <relay>
        CODE=$(curl -s -o "$WORK/resp" -w "%{http_code}" -D "$WORK/hdr" -X POST \
            --data-urlencode "SAMLResponse@$1" --data-urlencode "RelayState=$2" "$API/sso/saml/acs")
        BODY=$(cat "$WORK/resp"); LOCATION=$(grep -i '^location:' "$WORK/hdr" | tr -d '\r' | cut -d' ' -f2-)
    }
    make_resp "$RID" "$WORK/idp_key.pem" "$WORK/good.b64"
    post_acs "$WORK/good.b64" "/ui"
    [ "$CODE" = 302 ] && ok "ACS: 302" || fail "ACS: $CODE $BODY"
    case "$LOCATION" in /ui#token=*) ok "zurueck auf /ui mit #token";; *) fail "Location '$LOCATION'";; esac
    CAROL="${LOCATION#*#token=}"
    req GET /cluster "$CAROL"; [ "$CODE" = 200 ] && ok "carol (SAML-Gruppe devs) liest den Cluster" || fail "carol: $CODE $BODY"
    post_acs "$WORK/good.b64" "/ui"; [ "$CODE" = 401 ] && ok "dieselbe Antwort noch einmal → 401 (Kennung verbraucht)" || fail "Wiederholung: $CODE"
    # fremder Schluessel
    LOC=$(curl -s -o /dev/null -w "%{redirect_url}" "$API/sso/saml/login")
    RID2=$(python3 -c "import sys,urllib.parse,base64,zlib,re; q=urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query); print(re.search(r'ID=\"([^\"]+)\"', zlib.decompress(base64.b64decode(q['SAMLRequest'][0]),-15).decode()).group(1))" "$LOC")
    make_resp "$RID2" "$WORK/evil_key.pem" "$WORK/evil.b64"
    post_acs "$WORK/evil.b64" ""; [ "$CODE" = 401 ] && ok "fremdes Zertifikat → 401" || fail "fremd: $CODE $BODY"
    # unbekannte Kennung (IdP-initiiert)
    make_resp "_nicht_angefragt" "$WORK/idp_key.pem" "$WORK/unsol.b64"
    post_acs "$WORK/unsol.b64" ""; [ "$CODE" = 401 ] && ok "unangefragte Antwort → 401" || fail "unangefragt: $CODE $BODY"
    # fremdes Umleitungsziel: kein Sprung, JSON
    LOC=$(curl -s -o /dev/null -w "%{redirect_url}" "$API/sso/saml/login")
    RID3=$(python3 -c "import sys,urllib.parse,base64,zlib,re; q=urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query); print(re.search(r'ID=\"([^\"]+)\"', zlib.decompress(base64.b64decode(q['SAMLRequest'][0]),-15).decode()).group(1))" "$LOC")
    make_resp "$RID3" "$WORK/idp_key.pem" "$WORK/third.b64"
    post_acs "$WORK/third.b64" "//evil.example/steal"
    [ "$CODE" = 200 ] && [ -z "$LOCATION" ] && ok "RelayState '//evil…' → keine Umleitung" || fail "offener Umleiter: $CODE '$LOCATION'"
fi

grep -q "alice-pw\|bob-pw" "$LOGS"/e2e_id_*.log && fail "Passwort im Log" || ok "kein Passwort im Log"
echo
if [ "$FAILS" -eq 0 ]; then echo "E2E IDENTITY: PASS"; exit 0; fi
echo "E2E IDENTITY: $FAILS FAIL"; exit 1
