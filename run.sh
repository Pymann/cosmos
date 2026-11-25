#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--build" ]; then
    # shellcheck disable=SC1091
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    aiml build -c exodus-server.json
fi

./server
