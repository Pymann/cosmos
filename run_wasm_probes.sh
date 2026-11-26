#!/usr/bin/env bash
# The wasm probes (exodus-test-*-wasm.json): built by `aiml build` with
# output_type wasm (aiml spec/68 §7.1, F68-88/89), run in node.  They check
# what only wasm catches -- out-of-bounds access that native code lets pass.
#
# Needs: an aiml venv whose release carries lib/wasm32 (F68-90), emcc of
# the emsdk version named in $AIML_VENV/lib/wasm32/emsdk.version, node.
# Each probe names its exit code in a "# Expected exit code: N" line.
set -u
cd "$(dirname "$0")"
: "${AIML_MEM_V3:=1}"; export AIML_MEM_V3
mkdir -p logs
fails=0
for cfg in exodus-test-*-wasm.json; do
    name=$(jq -r .name "$cfg")
    src=$(jq -r '.sources[0]' "$cfg")
    want=$(sed -n 's/^# Expected exit code: *\([0-9]*\).*/\1/p' "$src" | head -1)
    want=${want:-0}
    if ! aiml build -c "$cfg" > "logs/wasm_$name.build.log" 2>&1; then
        echo "[wasm] FAIL $name: build (logs/wasm_$name.build.log)"; tail -5 "logs/wasm_$name.build.log"
        fails=$((fails + 1)); continue
    fi
    # --no-concurrent-recompilation: at exit node drains its platform tasks
    # while a background TurboFan job waits for a GC only the main thread can
    # run -- a V8 deadlock after main has returned (liveshape_wasm hung in 9 of
    # 10 runs after printing PASS).  Optimizing on the main thread avoids it.
    timeout 120 node --no-concurrent-recompilation "out/$name/$name.js" > "logs/wasm_$name.run.log" 2>&1
    rc=$?
    if [ "$rc" -eq "$want" ]; then
        echo "[wasm] ok   $name (exit $rc)"
    else
        [ "$rc" -eq 124 ] && why="no exit within 120 s" || why="exit $rc, expected $want"
        echo "[wasm] FAIL $name: $why (logs/wasm_$name.run.log)"; tail -5 "logs/wasm_$name.run.log"
        fails=$((fails + 1))
    fi
done
[ "$fails" -eq 0 ] && { echo "[wasm] PASS"; exit 0; }
echo "[wasm] $fails probe(s) failed"; exit 1
