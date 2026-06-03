#!/usr/bin/env bash
# ============================================================================
# run.sh — launch the game.
# ----------------------------------------------------------------------------
#   ./scripts/run.sh             # desktop: opens a real window (needs a GPU/display)
#   HEADLESS=1 ./scripts/run.sh  # server:  Xvfb + software OpenGL, no display needed
# ============================================================================
set -euo pipefail

GODOT="${GODOT_PATH:-/home/user/tools/godot/godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${HEADLESS:-0}" = "1" ]; then
  export LIBGL_ALWAYS_SOFTWARE=1
  exec xvfb-run -a -s "-screen 0 1600x900x24" \
    "$GODOT" --path "$ROOT" \
    --rendering-method gl_compatibility --rendering-driver opengl3
else
  exec "$GODOT" --path "$ROOT"
fi
