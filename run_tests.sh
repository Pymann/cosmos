#!/usr/bin/env bash
# Logik-Tests (ohne Display, ohne Netz) gebündelt bauen und laufen lassen.
#   ./run_tests.sh            # bauen + laufen
#   ./run_tests.sh --run-only # nur laufen (vorhandene Binaries)
# Jeder Test ist ein eigenes Binary; sie laufen in einem eigenen Arbeitsverzeichnis,
# damit die AionDB-Stores der Tests den Server-Store nicht anfassen.
set -uo pipefail
cd "$(dirname "$0")"

TESTS=(test_job_params test_queue_order test_pipe_scene test_step_env test_step_notes test_job_lifecycle test_step_dispatch test_presence test_step_scheduler test_matrix_view test_live_table test_run_pipeline test_auth_cluster test_agent_exec test_cas_blobs test_cas_trees test_cas_actions test_cas_immutable test_run_authz test_step_runner test_provision_plan test_provision_run test_live_push_sig test_dashboard test_console t_res test_oci test_stage_marks)
CONFIGS=(exodus-test-jobparams.json exodus-test-queue.json exodus-test-pipescene.json exodus-test-stepenv.json exodus-test-stepnotes.json exodus-test-joblife.json exodus-test-dispatch.json exodus-test-presence.json exodus-test-sched.json exodus-test-matrix.json exodus-test-livetable.json exodus-test-runpipe.json exodus-test-auth.json exodus-test-agent.json exodus-test-cas.json exodus-test-castrees.json exodus-test-actions.json exodus-test-immut.json exodus-test-authz.json exodus-test-step.json exodus-test-provplan.json exodus-test-provrun.json exodus-test-pushsig.json exodus-test-dashboard.json exodus-test-console.json exodus-test-res.json runtime/exodus-rt-oci-test.json exodus-test-marks.json)

if [ "${1:-}" != "--run-only" ]; then
    # shellcheck disable=SC1091
    # aiml spec/68: die Konfigurationen nehmen Compiler und Laufzeit aus einer
    # venv ($AIML, $AIML_VENV) — die Standard-venv, falls keine aktiv ist.
    [ -n "${AIML:-}" ] || [ ! -f ../../aimlvenv/env ] || . ../../aimlvenv/env
    for cfg in "${CONFIGS[@]}"; do
        echo "=== building $cfg ==="
        if ! aiml build -c "$cfg"; then
            echo "BUILD FAILED: $cfg"
            exit 1
        fi
    done
fi

# EIN frisches Verzeichnis JE TEST, nicht eines fuer alle: ein gemeinsamer
# Speicher liess Tests sich gegenseitig sehen — `claim_for` griff sich den
# wartenden Schritt eines anderen Tests, und derselbe Test fiel in 1 von 4
# Durchlaeufen um (gemessen 2026-10-15).  Dazu ein Zeitlimit: ohne eines haelt
# ein haengender Test die ganze Suite auf.
PROJ="$PWD"          # Projektwurzel, fuer Proben die Artefakte brauchen
ROOT="$PWD/.test_run"
rm -rf "$ROOT"
mkdir -p "$ROOT"
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

FAILED=0
for tst in "${TESTS[@]}"; do
    if [ ! -x "./$tst" ]; then
        echo "[ MISS ] $tst (not built)"
        FAILED=$((FAILED + 1))
        continue
    fi
    WORK="$ROOT/$tst"
    mkdir -p "$WORK"
    cp "./$tst" "$WORK/"
    echo "--------------------------------------------------------"
    # COSMOS_ROOT: die Probe laeuft in einem eigenen Verzeichnis, die Artefakte
    # (Angebots-Bibliothek, Tabelle, Praeambel) liegen aber im Projekt — doc/spec/108.
    ( cd "$WORK" && COSMOS_ROOT="$PROJ" AIONDB_PATH="$WORK/aiondb" timeout -k 5 "$TEST_TIMEOUT" "./$tst" )
    code=$?
    if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
        echo "[ FAIL ] $tst (Zeitgrenze ${TEST_TIMEOUT}s ueberschritten)"
        FAILED=$((FAILED + 1))
        continue
    fi
    if [ $code -eq 0 ]; then
        echo "[ PASS ] $tst"
    else
        echo "[ FAIL ] $tst (exit $code)"
        FAILED=$((FAILED + 1))
    fi
done

echo "========================================================"
if [ $FAILED -eq 0 ]; then
    echo "all ${#TESTS[@]} logic tests passed"
else
    echo "$FAILED of ${#TESTS[@]} logic tests failed"
fi
exit $FAILED
