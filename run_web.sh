#!/usr/bin/env bash
# run_web.sh — Cosmos browser variant (3 binaries):
#   cosmosd  (exodus-cosmosd.json) → ws://0.0.0.0:8770   (auth + cluster read)
#   static   (exodus-static.json)  → http://0.0.0.0:8090 (serves out/client/)
#   client   (exodus-client.json)  → WASM bundle out/client/client.{html,js,wasm,data}
#
# Browser opens http://127.0.0.1:8090/ ; der WASM-Client holt die Adresse des
# Controllers aus /servers.json (der Static-Host leitet sie aus COSMOS_BIND ab)
# und faellt nur ohne Liste auf ws://<host>:8765 zurueck.
#   ./run_web.sh --build   # build all three, then start cosmosd + static
#   ./run_web.sh           # start only (needs prior build)
#   ./run_web.sh --tls     # self-signed dev cert → https:8453 + wss:8770
set -uo pipefail
cd "$(dirname "$0")"
# EIGENE Ports, nicht die von 9rooms (das belegt 8765 Spiel, 8766 Medien,
# 8080 Oberflaeche).  Zwei Stapel auf einem Rechner sollen nebeneinander
# laufen koennen, ohne dass einer den anderen vom Port draengt — und der
# Fehler „Port belegt" ist beim Start leicht zu uebersehen.
#   COSMOS_BIND         Controller-WS   (Vorgabe ws://0.0.0.0:8770)
#   COSMOS_STATIC_PORT  Oberflaeche     (Vorgabe 8090, mit TLS 8453)
export COSMOS_BIND="${COSMOS_BIND:-ws://0.0.0.0:8770}"
export COSMOS_STATIC_PORT="${COSMOS_STATIC_PORT:-8090}"

export AIONDB_PATH="${AIONDB_PATH:-$PWD/aiondb}"; mkdir -p "$AIONDB_PATH"
mkdir -p logs

# Container-Vorgaben (doc/spec/110 §110.31).  Ohne sie lehnt die Einreichung
# jede Pipeline mit `image:` ab — zu Recht, aber wer den Stapel startet, will
# ihn benutzen koennen, ohne sieben Variablen auswendig zu kennen.  Alles
# ueberschreibbar: gesetzte Werte bleiben stehen.
export COSMOS_RT_AUTOSCALE="${COSMOS_RT_AUTOSCALE:-1}"
export COSMOS_RT_BINARY="${COSMOS_RT_BINARY:-./cosmos-rt}"
export COSMOS_RT_IMAGE="${COSMOS_RT_IMAGE:-$PWD/deploy/rt_image}"
export COSMOS_RT_IMAGES="${COSMOS_RT_IMAGES:-ubuntu-base=$PWD/deploy/rt_image}"
export COSMOS_RT_LABELS="${COSMOS_RT_LABELS:-x86_64,linux}"
export COSMOS_RT_LIMIT_MB="${COSMOS_RT_LIMIT_MB:-12288}"
export COSMOS_RT_MAX="${COSMOS_RT_MAX:-1}"
# Lokale Spiegel nach /src: damit klonen die Proben ohne Netz und ohne Zugang.
export COSMOS_RT_SRC="${COSMOS_RT_SRC:-$(cd ../.. && pwd)}"
# Freigaben (doc/spec/110 §110.35): NAME=Pfad, mit optionalem ":ro" als Zusage
# des Betreibers.  Eine Pipeline nennt nur den Namen — damit kann sie sich kein
# Verzeichnis des Wirts aussuchen.  Ohne Eintrag gibt es keine Freigaben, und
# eine Pipeline, die eine verlangt, wird abgewiesen (statt leer zu starten).
#   COSMOS_RT_SHARES="quellen=/srv/nfs/quellen:ro,ablage=/srv/ablage"
export COSMOS_RT_SHARES="${COSMOS_RT_SHARES:-}"
export AIML_MEM_V3="${AIML_MEM_V3:-1}"
if [ ! -d "$COSMOS_RT_IMAGE" ]; then
  echo "[web] HINWEIS: $COSMOS_RT_IMAGE fehlt — Pipelines mit 'image:' werden abgelehnt."
  echo "[web]           Abbild bauen: deploy/collect_runtime.sh && tools/make_agent_image.sh"
fi

TLS=0; for a in "$@"; do [ "$a" = "--tls" ] && TLS=1; done
if [ "$TLS" = "1" ]; then
  CERT_DIR="$PWD/tls_certs"; mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_DIR/server.crt" ]; then
    echo "[web] self-signed dev cert → $CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CERT_DIR/server.key" \
      -out "$CERT_DIR/server.crt" -days 3650 -subj "/CN=localhost" 2>/dev/null
  fi
  export COSMOS_TLS_CERT="${COSMOS_TLS_CERT:-$CERT_DIR/server.crt}"
  export COSMOS_TLS_KEY="${COSMOS_TLS_KEY:-$CERT_DIR/server.key}"
  # Mit TLS dasselbe Port-Schema, nur verschluesselt.
  export COSMOS_BIND="${COSMOS_BIND:-wss://0.0.0.0:8770}"
fi

if [ "${1:-}" = "--build" ]; then
  [ -f ../../exvenv/bin/activate ] && source ../../exvenv/bin/activate
  # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
  # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
  [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
  echo "[web] build cosmosd"; aiml build -c exodus-cosmosd.json || exit 1
  echo "[web] build console-offer (doc/spec/108)"; aiml build -c exodus-console-offer.json || exit 1
  echo "[web] build static";  aiml build -c exodus-static.json  || exit 1
  echo "[web] build client (WASM)"; exodus build -c exodus-client.json || exit 1
fi

[ -x ./cosmosd ] || { echo "missing ./cosmosd — run with --build"; exit 1; }
[ -x ./static ]  || { echo "missing ./static — run with --build"; exit 1; }

# Belegte Ports VORHER melden — sonst beendet sich cosmosd/static sofort wieder
# und das Skript verschwand früher ohne erkennbaren Grund.
WS_PORT="${COSMOS_BIND:-ws://0.0.0.0:8765}"; WS_PORT="${WS_PORT##*:}"
HTTP_PORT="${COSMOS_STATIC_PORT:-}"
if [ -z "$HTTP_PORT" ]; then
  if [ "$TLS" = "1" ]; then HTTP_PORT=8453; else HTTP_PORT=8090; fi
fi
# Belegte Ports: EIGENE Reste raeumt das Skript selbst weg, fremde nicht.
#
# Blind zu killen waere schlimmer als der Abbruch — auf 8080 kann etwas ganz
# anderes lauschen.  Darum wird ueber /proc/<pid>/exe geprueft, ob der Prozess
# WIRKLICH das cosmosd oder static DIESES Verzeichnisses ist; nur dann wird er
# beendet.  (Nach einem Rebuild steht dort "... (deleted)" — das Suffix faellt
# weg, sonst wuerde ein frisch gebauter Stack nie als eigener erkannt.)
own_binary() {   # $1 = pid → 0 wenn es unser cosmosd/static ist
  local exe; exe="$(readlink -f "/proc/$1/exe" 2>/dev/null)"
  exe="${exe% (deleted)}"
  [ "$exe" = "$PWD/cosmosd" ] || [ "$exe" = "$PWD/static" ]
}

pids_on_port() { # $1 = port
  ss -ltnp 2>/dev/null | grep ":${1} " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

PORT_BUSY=0
for p in "$WS_PORT" "$HTTP_PORT"; do
  ss -ltn 2>/dev/null | grep -q ":${p} " || continue
  for pid in $(pids_on_port "$p"); do
    if own_binary "$pid"; then
      echo "[web] Port $p: eigener Rest (pid=$pid) wird beendet"
      kill "$pid" 2>/dev/null
    else
      echo "[web] FEHLER: Port $p ist von einem FREMDEN Prozess belegt:"
      ss -ltnp 2>/dev/null | grep ":${p} " | sed 's/^/        /'
      PORT_BUSY=1
    fi
  done
done

# Auf das Freiwerden warten, statt sofort in "address in use" zu laufen.
for p in "$WS_PORT" "$HTTP_PORT"; do
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ss -ltn 2>/dev/null | grep -q ":${p} " || break
    sleep 0.3
  done
  if ss -ltn 2>/dev/null | grep -q ":${p} "; then
    for pid in $(pids_on_port "$p"); do
      own_binary "$pid" && { echo "[web] Port $p haengt — pid=$pid bekommt SIGKILL"; kill -9 "$pid" 2>/dev/null; }
    done
    sleep 0.5
  fi
done

if [ "$PORT_BUSY" = "1" ]; then
  echo "[web] Abbruch: fremde Prozesse werden NICHT beendet."
  exit 1
fi

echo "[web] starting cosmosd + static (logs/)"
# doc/spec/108: die Skript-Konsole braucht drei Artefakte (Angebots-Bibliothek,
# Tabelle, Praeambel) und einen Ort fuer den Schnappschuss.  Absolute Pfade, weil der
# Konsolen-Prozess ein KIND ist und sein Arbeitsverzeichnis nicht geerbt haben muss.
# Fehlt eines, sagt cosmosd das BEIM START (F108-9b) und die Konsole bleibt zu —
# statt dass das erste Skript eines Nutzers als Absturz zurueckkommt.
export COSMOS_CONSOLE_AIML="${COSMOS_CONSOLE_AIML:-$PWD/../aiml/out/aiml/aiml}"
export COSMOS_CONSOLE_EXPORTS="${COSMOS_CONSOLE_EXPORTS:-$PWD/deploy/clearance/console_exports.txt}"
export COSMOS_CONSOLE_PREAMBLE="${COSMOS_CONSOLE_PREAMBLE:-$PWD/deploy/clearance/console_preamble.aiml}"
export COSMOS_CONSOLE_LIB="${COSMOS_CONSOLE_LIB:-$PWD/libcosmos_console_offer.so}"
export COSMOS_CONSOLE_SNAPSHOT="${COSMOS_CONSOLE_SNAPSHOT:-$PWD/logs/console_snapshot.txt}"
export COSMOS_CONSOLE_WORK="${COSMOS_CONSOLE_WORK:-$PWD/logs/console_runs}"
COSMOS_LOG_FILE="$PWD/logs/cosmosd.log" ./cosmosd > logs/cosmosd.out 2>&1 &
CD=$!
./static > logs/static.log 2>&1 &
ST=$!
trap 'kill $CD $ST 2>/dev/null' INT TERM EXIT

# Kurz prüfen, dass beide wirklich lauschen — ein stilles Sofort-Ende ist sonst
# nur in den Logs sichtbar.
sleep 1
for _ in $(seq 1 30); do
  grep -q "listening on\|listening (TLS)" logs/cosmosd.log 2>/dev/null && break
  sleep 0.2
done
if ! kill -0 "$CD" 2>/dev/null; then
  echo "[web] FEHLER: cosmosd ist sofort beendet — letzte Zeilen:"; tail -5 logs/cosmosd.out; exit 1
fi
if ! kill -0 "$ST" 2>/dev/null; then
  echo "[web] FEHLER: static ist sofort beendet — letzte Zeilen:"; tail -5 logs/static.log; exit 1
fi

echo "[web] cosmosd pid $CD, static pid $ST — open http://127.0.0.1:${HTTP_PORT}/   (Ctrl+C to stop)"
echo "[web] for the cluster Jobs section, run controller+agent with the SAME AIONDB_PATH=$AIONDB_PATH,"
echo "      e.g.: AIONDB_PATH=$AIONDB_PATH ./controller --job-id job-deploy-api --command \"echo hi; sleep 3\" --exit-when-done &"
wait
