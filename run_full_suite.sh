#!/bin/bash
# run_full_suite.sh — TESTING_SOP.md L1–L5 one-shot orchestrator.
# Each layer gates the next: a failure stops the pipeline with the layer's
# log archived under /tmp/dw_test_logs/<timestamp>/.
#
# Usage:
#   ./run_full_suite.sh            # L1..L5 (L4 real-network integration ~5-7 min)
#   ./run_full_suite.sh --fast     # L1..L3 + L5 (skip network integration)
#   ./run_full_suite.sh --from L4  # resume at a layer (SOP §5: only for
#                                  #  re-running after a PASSING full chain)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/tmp/dw_test_logs/$LOG_TS"
mkdir -p "$LOG_DIR"
LUAJIT="${LUAJIT:-/tmp/koreader-emusrc/base/build/arm64-apple-darwin25.5.0-debug/luajit}"

FAILED_LAYER=""
declare -a SUMMARY

log_line() { printf '%s\n' "$*"; }

print_summary() {
    log_line ""
    log_line "================= SUMMARY ($mode) ================="
    printf '%s\n' "${SUMMARY[@]}"
    log_line "logs: $LOG_DIR"
}

run_layer() {
    local layer="$1" name="$2"; shift 2
    log_line ""
    log_line "=================================================================="
    log_line "[$layer] $name  ($(date +%H:%M:%S))"
    log_line "=================================================================="
    local t0=$(date +%s)
    if "$@" > "$LOG_DIR/${layer}.log" 2>&1; then
        local dt=$(( $(date +%s) - t0 ))
        local tail_line
        tail_line=$(tail -1 "$LOG_DIR/${layer}.log")
        SUMMARY+=("PASS  $layer  ${dt}s  $name")
        log_line "  -> PASS (${dt}s)  [$LOG_DIR/${layer}.log]"
        [ -n "$tail_line" ] && log_line "  -> $tail_line"
        return 0
    else
        local rc=$?
        local dt=$(( $(date +%s) - t0 ))
        SUMMARY+=("FAIL  $layer  ${dt}s  $name")
        FAILED_LAYER="$layer"
        log_line "  -> FAIL (exit $rc, ${dt}s). Log: $LOG_DIR/${layer}.log"
        log_line "----- last 25 lines ---------------------------------------------"
        tail -25 "$LOG_DIR/${layer}.log" | sed 's/^/  | /'
        return $rc
    fi
}

l1_luacheck() {
    # L1: static analysis, CI parity (luacheck 0.26.x, lua51 std). Order:
    # 1) system luacheck if it actually WORKS (homebrew's 5.5-linked build
    #    crashes on its own standards.lua), 2) the repo's luajit runner with
    #    the emu-tree luacheck source + KOReader lfs module.
    cd "$REPO_ROOT" || return 1
    if command -v luacheck >/dev/null 2>&1 && luacheck --version >/dev/null 2>&1; then
        luacheck dual_wiki.koplugin tests
    else
        : "${LUACHECK_SRC:=/tmp/koreader-emusrc/luacheck}"
        : "${LFS_SO:=/tmp/koreader-emusrc/base/build/arm64-apple-darwin25.5.0-debug/libs/libkoreader-lfs.so}"
        export LUACHECK_SRC LFS_SO
        luajit tools/luacheck_runner.lua
    fi
}

l3_deploy_smoke() {
    cd "$REPO_ROOT" || return 1
    ./deploy-emu.sh deploy && ./deploy-emu.sh smoke 15
}

mode="${1:-full}"

log_line "DualWiki full test suite — SOP v2 ($mode mode)"
log_line "logs: $LOG_DIR"

run_layer L1 "static analysis" l1_luacheck \
    || { log_line "STOPPED at L1 (gate: L2 needs clean statics)"; print_summary; exit 1; }

run_layer L2 "syntax + unit tests" "$REPO_ROOT/deploy-emu.sh" test \
    || { log_line "STOPPED at L2 (gate: pure-function regressions)"; print_summary; exit 1; }

run_layer L2b "transport unit tests" "$LUAJIT" "$REPO_ROOT/tests/test_keepalive.lua" \
    "$REPO_ROOT/dual_wiki.koplugin/keepalive.lua" \
    || { log_line "STOPPED at L2b (gate: keepalive regressions)"; print_summary; exit 1; }

run_layer L3 "deploy + smoke" l3_deploy_smoke \
    || { log_line "STOPPED at L3 (gate: plugin must load in the real runtime)"; print_summary; exit 1; }

if [ "$mode" != "--fast" ]; then
    run_layer L4 "real-network integration (~5-7 min)" "$REPO_ROOT/deploy-emu.sh" integration \
        || { log_line "STOPPED at L4 (gate: engine/pipeline contracts)"; print_summary; exit 1; }
fi

run_layer L5 "coexistence conflicts" "$REPO_ROOT/deploy-emu.sh" conflicts \
    || { log_line "STOPPED at L5 (gate: plugin ecosystem isolation)"; print_summary; exit 1; }

print_summary
log_line ""
log_line "ALL AUTOMATED LAYERS PASSED — proceed to L6 (./deploy-emu.sh run + tests/MANUAL_CHECKLIST.md)"
exit 0
