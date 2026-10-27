#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--build" ]; then
    # shellcheck disable=SC1091
    source ../../exvenv/bin/activate
    exodus build -c exodus-server.json
fi

./server
