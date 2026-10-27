#!/usr/bin/env bash
# Baut die C-Unterkante und danach das aiml-Ziel (doc/spec/110 F110-1).
# Die Unterkante ist eine eigene .so, damit sie auch im JIT-Pfad auffindbar ist.
set -uo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-exodus-rt-probe.json}"
echo "[rt] Shim übersetzen ($(uname -m))"
gcc -shared -fPIC -O1 -Wall -Wextra -o runtime/shim/librt_shim.so runtime/shim/rt_shim.c || exit 1
source ../../exvenv/bin/activate
exec ./tools/build_check.sh "runtime/$TARGET"
