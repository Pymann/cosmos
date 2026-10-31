#!/usr/bin/env bash
# run_prod.sh — Cosmos production launch (TLS via Let's Encrypt, systemd units).
#   Reads prod.env (DOMAIN=cosmos.example.com).  Certs from /etc/letsencrypt/live/$DOMAIN/.
#   Modes: --build | --systemd | --run (default --run).
# Ports: cosmosd wss://0.0.0.0:8765, static https://0.0.0.0:443.
set -uo pipefail
cd "$(dirname "$0")"
[ -f prod.env ] && . ./prod.env
DOMAIN="${DOMAIN:-localhost}"
LE="/etc/letsencrypt/live/$DOMAIN"
export COSMOS_TLS_CERT="${COSMOS_TLS_CERT:-$LE/fullchain.pem}"
export COSMOS_TLS_KEY="${COSMOS_TLS_KEY:-$LE/privkey.pem}"
export COSMOS_BIND="${COSMOS_BIND:-wss://0.0.0.0:8765}"
export COSMOS_STATIC_PORT="${COSMOS_STATIC_PORT:-443}"
export AIONDB_PATH="${AIONDB_PATH:-$PWD/aiondb}"; mkdir -p "$AIONDB_PATH" logs

MODE="${1:---run}"
case "$MODE" in
  --build)
    # In einem Container liegt exodus woanders und steht schon auf PATH.
    [ -f ../../exvenv/bin/activate ] && source ../../exvenv/bin/activate
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    exodus build -c exodus-cosmosd.json && exodus build -c exodus-static.json && exodus build -c exodus-client.json ;;
  --systemd)
    mkdir -p deploy/systemd
    for unit in cosmosd static; do
      cat > "deploy/systemd/cosmos-$unit.service" <<UNIT
[Unit]
Description=Cosmos $unit
After=network.target
[Service]
Type=simple
User=cosmos
WorkingDirectory=$PWD
EnvironmentFile=$PWD/prod.env
Environment=AIONDB_PATH=$PWD/aiondb
Environment=COSMOS_TLS_CERT=$COSMOS_TLS_CERT
Environment=COSMOS_TLS_KEY=$COSMOS_TLS_KEY
Environment=COSMOS_BIND=$COSMOS_BIND
Environment=COSMOS_STATIC_PORT=$COSMOS_STATIC_PORT
ExecStart=$PWD/$unit
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$PWD/aiondb $PWD/logs
[Install]
WantedBy=multi-user.target
UNIT
    done
    echo "systemd units written to deploy/systemd/ (install: sudo cp deploy/systemd/*.service /etc/systemd/system/)" ;;
  --run)
    [ -x ./cosmosd ] && [ -x ./static ] || { echo "build first (--build)"; exit 1; }
    COSMOS_LOG_FILE="$PWD/logs/cosmosd.log" ./cosmosd > logs/cosmosd.out 2>&1 &
    ./static > logs/static.log 2>&1 &
    trap 'kill 0' INT TERM EXIT; wait ;;
  *) echo "usage: run_prod.sh [--build|--systemd|--run]"; exit 2 ;;
esac
