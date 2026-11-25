#!/bin/bash
# cosmos auf dem kontor-Server einrichten (doc/spec/112 §112.4).
#
#   sudo deploy/server/install.sh [Optionen]
#
#   --from <dir>               cosmos-Checkout mit den gebauten Binaries
#                              (cosmosd, cosmos-api, agent; Vorgabe: dieses Repo)
#   --venv <dir>               aiml-venv, aus der die Bibliotheken kommen (Vorgabe: $AIML_VENV)
#   --kontor-url <url>         wohin Pipelines hochladen (Vorgabe: https://127.0.0.1:8443)
#   --kontor-ca <datei>        CA/Zertifikat von kontor, falls selbstsigniert
#   --kontor-token-file <f>    kontor-Token mit Rolle writer (Datei, nie Argument)
#   --admin-email <adresse>    Admin-Konto von cosmos (Vorgabe: admin@cosmos.local)
#   --no-start                 alles ablegen, aber keinen Dienst starten
#
# Idempotent: ein zweiter Lauf erneuert Programme, Einheiten und Werkzeuge und
# laesst Zugaenge, Tokens und /etc/cosmos/cosmos.env stehen.  Fail closed:
# bricht ein Schritt ab, endet das Skript, und der Agent laeuft nicht.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FROM="$(cd "$HERE/../.." && pwd)"
VENV="${AIML_VENV:-}"
KONTOR_URL=""
KONTOR_CA=""
KONTOR_TOKEN_FILE=""
ADMIN_EMAIL="admin@cosmos.local"
START=1

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$(cd "$2" && pwd)"; shift 2 ;;
        --venv) VENV="$2"; shift 2 ;;
        --kontor-url) KONTOR_URL="$2"; shift 2 ;;
        --kontor-ca) KONTOR_CA="$2"; shift 2 ;;
        --kontor-token-file) KONTOR_TOKEN_FILE="$2"; shift 2 ;;
        --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
        --no-start) START=0; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unbekannte Option: $1 (--help)" >&2; exit 2 ;;
    esac
done

step() { echo; echo "== $*"; }
ok() { echo "   ok  $*"; }
die() { echo "   FEHLER: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "als root ausfuehren (sudo)"
command -v systemctl >/dev/null || die "systemd fehlt"

OPT=/opt/cosmos
ETC=/etc/cosmos
AETC=/etc/cosmos-agent
LIBEXEC=/usr/local/libexec/cosmos
DATA=/var/lib/cosmos
ADATA=/var/lib/cosmos-agent

# ------------------------------------------------------------------ 0. Pruefen
step "0. Voraussetzungen"
for bin in cosmosd cosmos-api agent; do
    [ -x "$FROM/$bin" ] || die "$FROM/$bin fehlt — erst bauen (GUIDE.md, Schritt 3): aiml build -c exodus-$( [ "$bin" = cosmos-api ] && echo api || echo "$bin").json"
done
ok "Binaries in $FROM"
[ -n "$VENV" ] || die "keine aiml-venv: --venv <dir> oder AIML_VENV setzen (sudo -E / sudo AIML_VENV=…)"
[ -f "$VENV/lib/libaiml.so" ] || die "$VENV/lib/libaiml.so fehlt — ist $VENV eine aiml-venv?"
ok "aiml-venv $VENV"
for f in "$KONTOR_CA" "$KONTOR_TOKEN_FILE"; do
    [ -z "$f" ] || [ -r "$f" ] || die "$f nicht lesbar"
done

# ------------------------------------------------------------------ 1. Pakete
step "1. Pakete"
need=()
for p in bubblewrap uidmap curl ca-certificates jq unzip git; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ -d /etc/apparmor.d ] && ! dpkg -s apparmor >/dev/null 2>&1; then need+=(apparmor); fi
if [ ${#need[@]} -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${need[@]}"
    ok "installiert: ${need[*]}"
else
    ok "alles da"
fi

# ------------------------------------------------------------------ 2. Nutzer
step "2. Dienstnutzer"
for u in cosmos cosmos-agent; do
    if id "$u" >/dev/null 2>&1; then ok "$u vorhanden"
    else useradd --system --user-group --home-dir "/var/lib/$u" --no-create-home --shell /usr/sbin/nologin "$u"; ok "$u angelegt"; fi
done
install -d -o cosmos -g cosmos -m 0750 "$DATA"
install -d -o cosmos-agent -g cosmos-agent -m 0750 "$ADATA" "$ADATA/steps"

# ------------------------------------------------------------------ 3. Programme
step "3. Programme und Ladekette nach $OPT"
install -d -m 0755 "$OPT" "$OPT/bin"
rm -rf "$OPT/lib.new"; install -d -m 0755 "$OPT/lib.new"
find "$VENV/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -exec cp -L {} "$OPT/lib.new/" \;
chmod 0644 "$OPT/lib.new"/*
rm -rf "$OPT/lib.old"; [ -d "$OPT/lib" ] && mv "$OPT/lib" "$OPT/lib.old"
mv "$OPT/lib.new" "$OPT/lib"; rm -rf "$OPT/lib.old"
for bin in cosmosd cosmos-api agent; do install -m 0755 "$FROM/$bin" "$OPT/bin/$bin.new"; mv -f "$OPT/bin/$bin.new" "$OPT/bin/$bin"; done
install -m 0755 "$(command -v bwrap)" "$OPT/bin/bwrap.new"; mv -f "$OPT/bin/bwrap.new" "$OPT/bin/bwrap"
chown -R root:root "$OPT"
missing="$(ldd "$OPT/bin/cosmosd" "$OPT/bin/cosmos-api" "$OPT/bin/agent" | grep 'not found' | sort -u || true)"
[ -z "$missing" ] || die "Bibliotheken fehlen:
$missing"
ok "$(ls "$OPT/lib" | wc -l) Bibliotheken, cosmosd/cosmos-api/agent/bwrap"

# ------------------------------------------------------------------ 4. AppArmor
step "4. AppArmor"
if [ -d /etc/apparmor.d ] && command -v apparmor_parser >/dev/null; then
    if [ -f /etc/apparmor.d/abi/4.0 ]; then
        install -m 0644 "$HERE/apparmor/cosmos-server" /etc/apparmor.d/cosmos-server
        apparmor_parser -r /etc/apparmor.d/cosmos-server
        ok "Profil cosmos-server geladen (bwrap, agent)"
    else
        ok "AppArmor ohne abi 4.0 (aelter als Ubuntu 24.04): User-Namespaces sind dort nicht eingeschraenkt — kein Profil noetig"
    fi
else
    ok "kein AppArmor auf diesem Rechner"
fi

# ------------------------------------------------------------------ 5. Werkzeuge
step "5. Werkzeuge"
install -d -m 0755 "$LIBEXEC"
install -m 0755 "$HERE/libexec/kontor-blob" "$LIBEXEC/kontor-blob"
install -m 0755 "$HERE/libexec/cosmosctl" /usr/local/sbin/cosmosctl
printf 'd %s 0750 cosmos-agent cosmos-agent 14d\n' "$ADATA/steps" > /etc/tmpfiles.d/cosmos-agent.conf
ok "kontor-blob ($LIBEXEC), cosmosctl (/usr/local/sbin), Aufraeumen nach 14 Tagen"

# ------------------------------------------------------------------ 6. Konfiguration
step "6. Konfiguration ($ETC, $AETC)"
install -d -m 0755 "$ETC" "$ETC/pipelines"
[ -f "$ETC/cosmos.env" ] || { install -m 0644 "$HERE/cosmos.env" "$ETC/cosmos.env"; ok "cosmos.env angelegt"; }
install -m 0644 "$HERE/cosmos.yaml" "$ETC/cosmos.yaml"
# Was fruehere Fassungen lieferten und heute nicht mehr gilt (F112-16).  Eigene
# Pipelines in $ETC/pipelines bleiben stehen.
for old in "$ETC/pipelines/aiml_to_kontor.yaml" "$LIBEXEC/aiml-mirror" "$AETC/aiml.env"; do
    [ -e "$old" ] || continue
    rm -f "$old"; ok "entfernt: $old (Spiegel-Pipeline ist herausgenommen, doc/spec/112 §112.5)"
done
ok "Erklaerung, $(find "$ETC/pipelines" -maxdepth 1 -name '*.yaml' | wc -l) Pipeline(s) in $ETC/pipelines"

install -d -o root -g cosmos-agent -m 0750 "$AETC"
setkey() {  # setkey <datei> <schluessel> <wert>: Zeile setzen, Rest stehen lassen
    local f="$1" k="$2" v="$3"
    touch "$f"
    if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else echo "$k=$v" >> "$f"; fi
}
KENV="$AETC/kontor.env"
if [ ! -f "$KENV" ]; then
    printf '# Zugang der Pipeline-Schritte zu kontor (doc/spec/112 F112-2, F112-7).\n' > "$KENV"
    setkey "$KENV" KONTOR_URL "${KONTOR_URL:-https://127.0.0.1:8443}"
    setkey "$KENV" KONTOR_TOKEN_FILE "$AETC/kontor.token"
fi
[ -z "$KONTOR_URL" ] || setkey "$KENV" KONTOR_URL "$KONTOR_URL"
if [ -n "$KONTOR_CA" ]; then
    install -o root -g cosmos-agent -m 0640 "$KONTOR_CA" "$AETC/kontor-ca.pem"
    setkey "$KENV" KONTOR_CA "$AETC/kontor-ca.pem"
fi
[ -z "$KONTOR_TOKEN_FILE" ] || install -o root -g cosmos-agent -m 0640 "$KONTOR_TOKEN_FILE" "$AETC/kontor.token"
chown root:cosmos-agent "$KENV"; chmod 0640 "$KENV"
ok "kontor.env → $(sed -n 's/^KONTOR_URL=//p' "$KENV")"
[ -f "$AETC/kontor.token" ] && ok "kontor-Token vorhanden" \
    || echo "   HINWEIS: $AETC/kontor.token fehlt — ohne es kann kein Schritt nach kontor hochladen (--kontor-token-file)"
[ ! -f "$AETC/github.token" ] \
    || echo "   HINWEIS: $AETC/github.token wird nicht mehr gebraucht (nur die Spiegel-Pipeline las es) — loeschen: sudo shred -u $AETC/github.token"

# ------------------------------------------------------------------ 7. Betriebshandlungen
step "7. Konto und Agent-Token (bei gestopptem Dienst, doc/spec/108 F108-3)"
systemctl stop cosmos-agent cosmos-api cosmosd 2>/dev/null || true
as_cosmos() { (cd "$DATA" && runuser -u cosmos -- env AIONDB_PATH="$DATA/aiondb" AIML_MEM_V3=1 "$OPT/bin/cosmosd" "$@"); }
if [ ! -s "$ETC/admin.password" ]; then
    pw="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    out="$(as_cosmos --add-user "$ADMIN_EMAIL" --add-user-pw "$pw" --add-user-nick admin 2>&1)" \
        || die "Konto $ADMIN_EMAIL liess sich nicht anlegen (existiert es schon? dann E-Mail und Passwort zeilenweise nach $ETC/admin.password):
$out"
    umask 077; printf '%s\n%s\n' "$ADMIN_EMAIL" "$pw" > "$ETC/admin.password"; umask 022
    chmod 0600 "$ETC/admin.password"
    ok "Konto $ADMIN_EMAIL angelegt, Passwort in $ETC/admin.password"
else
    ok "Konto vorhanden ($(head -1 "$ETC/admin.password"))"
fi
# Jedes Mal: setzt nur, was schon gilt — und heilt einen abgebrochenen ersten Lauf.
out="$(as_cosmos --grant-email "$(head -1 "$ETC/admin.password")" --grant-level 1 2>&1)" \
    || die "Freigabe 1 gescheitert:
$out"
ok "Freigabe 1 fuer $(head -1 "$ETC/admin.password")"
if [ ! -s "$ADATA/agent.token" ]; then
    tok="$(as_cosmos --mint-token kontor-server 2>/dev/null | tail -1)"
    [ -n "$tok" ] || die "Agent-Token liess sich nicht praegen"
    umask 077; printf '%s\n' "$tok" > "$ADATA/agent.token"; umask 022
    chown cosmos-agent:cosmos-agent "$ADATA/agent.token"; chmod 0600 "$ADATA/agent.token"
    ok "Agent-Token gepraegt → $ADATA/agent.token (0600)"
else
    ok "Agent-Token vorhanden"
fi

# ------------------------------------------------------------------ 8. Einheiten
step "8. systemd-Einheiten"
install -m 0644 "$HERE"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable cosmosd cosmos-api cosmos-agent >/dev/null 2>&1
systemd-tmpfiles --create /etc/tmpfiles.d/cosmos-agent.conf >/dev/null 2>&1 || true
ok "cosmosd, cosmos-api, cosmos-agent (aktiviert)"
if [ "$START" -eq 0 ]; then echo; echo "Fertig (--no-start): kein Dienst gestartet."; exit 0; fi

port="$(sed -n 's/^COSMOS_API_PORT=//p' "$ETC/cosmos.env" | tail -1)"; port="${port:-8771}"
API="http://127.0.0.1:$port/api/v1"
systemctl start cosmosd
systemctl start cosmos-api
for _ in $(seq 1 60); do
    curl -fs "$API/health" 2>/dev/null | grep -q '"cosmosd":1' && break
    sleep 1
done
curl -fs "$API/health" 2>/dev/null | grep -q '"cosmosd":1' \
    || { journalctl -u cosmosd -u cosmos-api -n 30 --no-pager >&2; die "cosmosd/cosmos-api antworten nicht auf $API/health"; }
ok "cosmosd + cosmos-api antworten ($API)"

# ------------------------------------------------------------------ 9. API-Token
step "9. API-Token fuer cosmosctl"
if [ ! -s "$ETC/api.token" ]; then
    email="$(sed -n 1p "$ETC/admin.password")"; pw="$(sed -n 2p "$ETC/admin.password")"
    body="$(jq -cn --arg e "$email" --arg p "$pw" '{email: $e, password: $p}')"
    sess="$(curl -fsS -X POST --data-binary @- "$API/login" <<<"$body" | jq -r '.token // empty')"
    [ -n "$sess" ] || die "Anmeldung als $email gescheitert"
    hdr="$(mktemp)"; chmod 600 "$hdr"; printf 'Authorization: Bearer %s\n' "$sess" > "$hdr"
    secret="$(curl -fsS -H @"$hdr" -X POST --data-binary '{"label":"cosmosctl"}' "$API/tokens" | jq -r '.secret // empty')"
    curl -fsS -H @"$hdr" -X POST "$API/logout" >/dev/null 2>&1 || true
    rm -f "$hdr"
    [ -n "$secret" ] || die "API-Token liess sich nicht anlegen"
    umask 077; printf '%s\n' "$secret" > "$ETC/api.token"; umask 022; chmod 0600 "$ETC/api.token"
    ok "API-Token → $ETC/api.token (0600)"
else
    ok "API-Token vorhanden"
fi

# ------------------------------------------------------------------ 10. Agent
step "10. Agent: erst Nachweis, dann Start (doc/spec/94 Schritt 9)"
probe="$(cd "$ADATA" && runuser -u cosmos-agent -- env AIML_MEM_V3=1 "$OPT/bin/agent" --verify-isolation 1 --bwrap-path "$OPT/bin/bwrap" 2>&1 || true)"
grep -q ISOLATION_OK <<<"$probe" || die "Isolation traegt nicht — der Agent wird NICHT gestartet:
$probe"
ok "Isolation traegt"
since="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl start cosmos-agent
for _ in $(seq 1 60); do
    journalctl -u cosmos-agent --since "$since" --no-pager -o cat 2>/dev/null | grep -q 'registered at' && break
    sleep 1
done
journalctl -u cosmos-agent --since "$since" --no-pager -o cat 2>/dev/null | grep -q 'registered at' \
    || { journalctl -u cosmos-agent -n 30 --no-pager >&2; die "der Agent hat sich nicht angemeldet"; }
ok "Agent angemeldet"

echo
echo "Fertig.  Weiter mit:  sudo cosmosctl status   |   sudo cosmosctl jobs"
