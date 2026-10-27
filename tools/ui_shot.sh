#!/usr/bin/env bash
# Nimmt cosmos-Prefab-Scenes headless auf (doc/spec/98).  Xvfb + ImageMagick
# sind in exodus-ui-shot.json als apt_packages deklariert.
#   tools/ui_shot.sh [SceneName ...]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=doc/spec/ui/shots
DISP=:99
HOLD=2500
SCENES=("$@")
if [ ${#SCENES[@]} -eq 0 ]; then
    SCENES=(LoginScene MainMenuScene PipelineScene ClusterScene AgentsScene)
fi
mkdir -p "$OUT"
Xvfb "$DISP" -screen 0 1280x720x24 >"$OUT/xvfb.log" 2>&1 &
XPID=$!
sleep 1
rc_all=0
for S in "${SCENES[@]}"; do
    DISPLAY="$DISP" ./ui_shot "$S" "$HOLD" >"$OUT/$S.log" 2>&1 &
    APID=$!
    sleep 1.4
    DISPLAY="$DISP" import -window root "$OUT/$S.png" 2>>"$OUT/$S.log"
    wait $APID; rc=$?
    if [ $rc -ne 0 ]; then rc_all=1; fi
    printf '%-16s rc=%s  %s\n' "$S" "$rc" "$(ls -la "$OUT/$S.png" 2>/dev/null | awk '{print $5" B"}')"
done
kill $XPID 2>/dev/null
exit $rc_all
