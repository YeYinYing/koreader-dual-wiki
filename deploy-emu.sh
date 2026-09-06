#!/bin/bash
# deploy-emu.sh — local KOReader macOS emulator workflow for dual_wiki.
# The emulator runs the real frontend (LuaJIT 2.1 + LuaSec + SDL3), so
# plugin code behaves exactly as on devices — no Kindle plugging needed.
#
# Usage:
#   ./deploy-emu.sh deploy   # cp plugin into the emu runtime
#   ./deploy-emu.sh test     # run unit tests with the emu's own LuaJIT
#   ./deploy-emu.sh run      # launch the emulator window (PW3-ish viewport)
#   ./deploy-emu.sh smoke N  # headless-ish bounded run: assert plugin loads, exit
#   ./deploy-emu.sh all      # deploy + test
set -euo pipefail

EMU_SRC="${EMU_SRC:-/tmp/koreader-emusrc}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$REPO_ROOT/dual_wiki.koplugin"
INSTALL_DIR="$EMU_SRC/koreader-emulator-arm64-apple-darwin25.5.0-debug"
RUNTIME_DIR="$INSTALL_DIR/koreader"
LUAJIT="$EMU_SRC/base/build/arm64-apple-darwin25.5.0-debug/luajit"
LIBRARY="${EMU_LIBRARY:-/tmp/koreader-emu-home/library}"

ensure_env() {
  export PATH="/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/util-linux/bin:/opt/homebrew/bin:$PATH"
}

do_deploy() {
  if [ ! -d "$RUNTIME_DIR" ]; then
    echo "emu runtime not found at $RUNTIME_DIR (run: cd $EMU_SRC && ./kodev build)" >&2
    exit 1
  fi
  rm -rf "$RUNTIME_DIR/plugins/dual_wiki.koplugin"
  cp -R "$PLUGIN_SRC" "$RUNTIME_DIR/plugins/dual_wiki.koplugin"
  echo "deployed -> $RUNTIME_DIR/plugins/dual_wiki.koplugin"
  mkdir -p "$LIBRARY"
  python3 "$REPO_ROOT/tests/make_test_books.py" "$LIBRARY" >/dev/null && echo "books  -> $LIBRARY (8 multilingual epubs)"
}

do_test() {
  echo "runtime: $("$LUAJIT" -v 2>&1 | head -1)"
  "$LUAJIT" "$REPO_ROOT/tests/test_query_helpers.lua" "$PLUGIN_SRC/main.lua"
}

do_integration() {
  # Real-network integration inside the emu runtime: every engine hit for
  # real (wikipedia zh/en/ja/de/fr/es/ru, moegirl, fandom, bwiki,
  # wiktionary) with only the UI surface stubbed. Throttles requests.
  if [ ! -d "$RUNTIME_DIR" ]; then
    echo "emu runtime not found (run: cd $EMU_SRC && ./kodev build)" >&2
    exit 1
  fi
  cd "$RUNTIME_DIR"
  "$LUAJIT" "$REPO_ROOT/tests/test_integration.lua"
}

do_conflicts() {
  # Coexistence contract: dual_wiki + vocabbuilder + gestures + coverbrowser
  # load together in the emu runtime with real widget classes; asserts
  # settings-namespace isolation and non-clobbering event behavior.
  local install_dir
  install_dir=$(ls -d "$EMU_SRC"/koreader-emulator-* 2>/dev/null | head -1)
  if [ -z "$install_dir" ]; then
    echo "emulator install dir not found under $EMU_SRC — run ./kodev build first" >&2
    exit 1
  fi
  cd "$install_dir/koreader"
  "$LUAJIT" "$REPO_ROOT/tests/test_conflicts.lua"
}

do_run() {
  ensure_env
  cd "$RUNTIME_DIR"
  # PW3 viewport: 1072x1448 @ 300dpi is the kindle-paperwhite preset used
  # by upstream; keep values explicit so the window always matches.
  exec env EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 \
    "$LUAJIT" reader.lua -d
}

do_smoke() {
  local secs="${1:-15}"
  ensure_env
  cd "$RUNTIME_DIR"
  set +e
  EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 \
    timeout "$secs" "$LUAJIT" reader.lua -d > /tmp/ko_smoke.log 2>&1
  local code=$?
  set -e
  local loaded
  loaded=$(rg -c "Plugin loaded dual_wiki" /tmp/ko_smoke.log || true)
  if [ "${loaded:-0}" -ge 1 ]; then
    echo "SMOKE OK: dual_wiki loaded (plugins=33 expected), exit=$code (124=timeout-boundary, expected)"
    exit 0
  else
    echo "SMOKE FAIL: dual_wiki did not load; log tail:" >&2
    tail -20 /tmp/ko_smoke.log >&2
    exit 1
  fi
}

case "${1:-all}" in
  deploy) do_deploy ;;
  test)   do_test ;;
  integration) do_integration ;;
  conflicts) do_conflicts ;;
  run)    do_run ;;
  smoke)  do_smoke "${2:-15}" ;;
  all)    do_deploy && do_test ;;
  *)      echo "usage: $0 {deploy|test|integration|conflicts|run|smoke [secs]|all}" >&2; exit 1 ;;
esac
