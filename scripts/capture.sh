#!/usr/bin/env bash
# ============================================================================
# capture.sh — headless proof that the title screen renders.
# ----------------------------------------------------------------------------
# Runs the verification harness (tools/capture.tscn) under Xvfb with software
# OpenGL, which loads the shipped title screen, draws a few frames, and writes
# docs/title_screen.png. No GPU required.
# ============================================================================
set -euo pipefail

GODOT="${GODOT_PATH:-/home/user/tools/godot/godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LIBGL_ALWAYS_SOFTWARE=1

xvfb-run -a -s "-screen 0 1600x900x24" \
  "$GODOT" --path "$ROOT" \
  --rendering-method gl_compatibility --rendering-driver opengl3 \
  "$ROOT/tools/capture.tscn"

echo ">> Wrote $ROOT/docs/title_screen.png"
